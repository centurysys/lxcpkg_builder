# Delta package support for lxcpkg.
#
# A .lxcdelta archive contains an overlayfs upperdir snapshot packed as
# delta.sqfs, plus a manifest that binds the delta to the exact base image
# SHA256. Unlike rebuild, this command does not create a merged rootfs image.

import std/json
import std/options
import std/os
import std/osproc
import std/streams
import std/strformat
import std/strutils
import std/times

import results

import archive
import cleanup
import errors
import manifest
import rebuild
import squashfs
import types

const
  deltaArchiveFormat* = "lxcdelta-v1"
  deltaArchiveExtension* = ".lxcdelta"
  deltaImageFileName* = "delta.sqfs"
  defaultDeltaCompression = compZstd
  defaultDeltaBlockSize = defaultBlockSize

type
  RawDeltaOptions* = object
    base*: Option[string]
    dev*: Option[string]
    output*: Option[string]
    version*: Option[string]
    compression*: Option[string]
    blockSize*: Option[string]
    exclude*: seq[string]
    clean*: bool
    scrub*: bool
    pruneEmptyDirs*: bool
    keepWorkdir*: bool
    force*: bool
    verbose*: bool

  DeltaOptions* = object
    basePackageFile*: string
    devArchiveFile*: string
    outputFile*: string
    version*: string
    compression*: Compression
    blockSize*: string
    extraExcludes*: seq[string]
    clean*: bool
    scrub*: bool
    pruneEmptyDirs*: bool
    keepWorkdir*: bool
    force*: bool
    verbose*: bool

proc invalidDeltaInput(message: string; detail = ""): LxError =
  result = newError(ekInvalidManifest, message, detail)

proc findTool(tool: string): LxResult[string] =
  let path = findExe(tool)
  if path.len == 0:
    return LxResult[string].err(externalToolMissing(tool))

  result = LxResult[string].ok(path)

proc formatCommand(command: string; args: seq[string]): string =
  if args.len == 0:
    return command

  result = command & " " & args.join(" ")

proc readProcessOutput(process: Process): LxResult[string] =
  try:
    result = LxResult[string].ok(process.outputStream.readAll())
  except IOError as e:
    result = LxResult[string].err(
      ioError("failed to read external command output", e.msg)
    )

proc runCommand(command: string; args: seq[string]; workingDir: string; verbose: bool): LxResult[void] =
  if verbose:
    echo formatCommand(command, args)

  let process =
    try:
      startProcess(
        command,
        workingDir = workingDir,
        args = args,
        options = {poUsePath, poStdErrToStdOut}
      )
    except OSError as e:
      return LxResult[void].err(ioError("failed to start external command", e.msg))

  let outputResult = readProcessOutput(process)
  if outputResult.isErr:
    process.close()
    return LxResult[void].err(outputResult.error())

  let code =
    try:
      process.waitForExit()
    finally:
      process.close()

  let output = outputResult.get()
  if code != 0:
    return LxResult[void].err(
      externalCommandFailed(command, code, output.strip())
    )

  if verbose and output.len > 0:
    stdout.write(output)

  result = LxResult[void].ok()

proc createDeltaDir(): LxResult[string] =
  let baseDir = getTempDir()
  let pid = getCurrentProcessId()

  for index in 0 ..< 1000:
    let path = baseDir / &"lxcpkg-delta-{pid}-{index}"
    if dirExists(path) or fileExists(path):
      continue

    try:
      createDir(path)
      return LxResult[string].ok(path)
    except OSError as e:
      return LxResult[string].err(
        ioError("failed to create temporary delta directory", e.msg)
      )

  result = LxResult[string].err(
    ioError("failed to create temporary delta directory", baseDir)
  )

proc removeDeltaDir(buildDir: string): LxResult[void] =
  if buildDir.len == 0:
    return LxResult[void].ok()

  try:
    removeDir(buildDir)
    result = LxResult[void].ok()
  except OSError as e:
    result = LxResult[void].err(ioError("failed to remove temporary delta directory", e.msg))

proc extractOverlaySnapshot(snapshotPath, upperDir: string; verbose: bool): LxResult[void] =
  let tool = findTool("tar")
  if tool.isErr:
    return LxResult[void].err(tool.error())

  let args = @[
    "--numeric-owner",
    "--xattrs",
    "--acls",
    "-I",
    "zstd",
    "-xf",
    snapshotPath,
    "-C",
    upperDir
  ]

  result = runCommand(tool.get(), args, getCurrentDir(), verbose)

proc createDirChecked(path, description: string): LxResult[void] =
  try:
    createDir(path)
    result = LxResult[void].ok()
  except OSError as e:
    result = LxResult[void].err(ioError(&"failed to create {description}", e.msg))

proc parseCompression(text: string): LxResult[Compression] =
  case text.strip()
  of "zstd":
    result = LxResult[Compression].ok(compZstd)
  of "xz":
    result = LxResult[Compression].ok(compXz)
  of "gzip":
    result = LxResult[Compression].ok(compGzip)
  of "lz4":
    result = LxResult[Compression].ok(compLz4)
  of "lzo":
    result = LxResult[Compression].ok(compLzo)
  else:
    result = LxResult[Compression].err(
      invalidArgument(
        "invalid squashfs compression",
        "allowed values: zstd, xz, gzip, lz4, lzo"
      )
    )

proc baseValue(opts: RawDeltaOptions): LxResult[string] =
  if opts.base.isSome and opts.base.get().len > 0:
    return LxResult[string].ok(opts.base.get())

  result = LxResult[string].err(missingArgument("--base"))

proc devValue(opts: RawDeltaOptions): LxResult[string] =
  if opts.dev.isSome and opts.dev.get().len > 0:
    return LxResult[string].ok(opts.dev.get())

  result = LxResult[string].err(missingArgument("--dev"))

proc outputValue(opts: RawDeltaOptions; manifest: PackageManifest; version: string): string =
  if opts.output.isSome and opts.output.get().len > 0:
    return ensureArchiveExtension(opts.output.get(), deltaArchiveExtension)

  result = ensureArchiveExtension(&"{manifest.name}-{version}", deltaArchiveExtension)

proc versionValue(opts: RawDeltaOptions; baseVersion: string): string =
  if opts.version.isSome and opts.version.get().len > 0:
    return opts.version.get()

  result = deriveRebuildVersion(baseVersion)
  if result == baseVersion:
    stderr.writeLine(&"warning: base version is not MAJOR.MINOR.PATCH; keeping version unchanged: {baseVersion}")

proc compressionValue(opts: RawDeltaOptions): LxResult[Compression] =
  if opts.compression.isSome:
    return parseCompression(opts.compression.get())

  result = LxResult[Compression].ok(defaultDeltaCompression)

proc blockSizeValue(opts: RawDeltaOptions): string =
  if opts.blockSize.isSome and opts.blockSize.get().len > 0:
    result = opts.blockSize.get()
  else:
    result = defaultDeltaBlockSize

proc resolveDeltaOptions*(
    opts: RawDeltaOptions,
    manifest: PackageManifest
): LxResult[DeltaOptions] =
  let baseResult = baseValue(opts)
  if baseResult.isErr:
    return LxResult[DeltaOptions].err(baseResult.error())

  let devResult = devValue(opts)
  if devResult.isErr:
    return LxResult[DeltaOptions].err(devResult.error())

  let version = versionValue(opts, manifest.version)

  let compressionResult = compressionValue(opts)
  if compressionResult.isErr:
    return LxResult[DeltaOptions].err(compressionResult.error())

  let output = outputValue(opts, manifest, version)
  let outputCheck = checkArchiveOutput(output, opts.force)
  if outputCheck.isErr:
    return LxResult[DeltaOptions].err(outputCheck.error())

  result = LxResult[DeltaOptions].ok(DeltaOptions(
    basePackageFile: baseResult.get(),
    devArchiveFile: devResult.get(),
    outputFile: output,
    version: version,
    compression: compressionResult.get(),
    blockSize: blockSizeValue(opts),
    extraExcludes: opts.exclude,
    clean: opts.clean,
    scrub: opts.scrub,
    pruneEmptyDirs: opts.pruneEmptyDirs,
    keepWorkdir: opts.keepWorkdir,
    force: opts.force,
    verbose: opts.verbose
  ))

proc createDeltaImage(opts: DeltaOptions; upperDir, buildDir: string): LxResult[string] =
  let imagePath = buildDir / deltaImageFileName
  let squashOpts = SquashfsOptions(
    sourceDir: upperDir,
    imageFile: imagePath,
    compression: opts.compression,
    blockSize: opts.blockSize,
    extraExcludes: opts.extraExcludes,
    verbose: opts.verbose
  )

  let squashResult = makeSquashfs(squashOpts)
  if squashResult.isErr:
    return LxResult[string].err(squashResult.error())

  result = LxResult[string].ok(imagePath)

proc deltaManifestToJson(
    opts: DeltaOptions,
    inputs: RebuildInputPaths,
    deltaSha256: string
): JsonNode =
  result = %*{
    "format": deltaArchiveFormat,
    "name": inputs.packageManifest.name,
    "packageId": inputs.packageManifest.packageId,
    "version": opts.version,
    "arch": $inputs.packageManifest.arch,
    "base": {
      "name": inputs.packageManifest.name,
      "version": inputs.packageManifest.version,
      "imageFile": inputs.packageManifest.image.file,
      "sha256": inputs.packageManifest.image.sha256
    },
    "delta": {
      "file": deltaImageFileName,
      "sha256": deltaSha256,
      "compression": $opts.compression
    },
    "createdAt": getTime().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  }

proc writeDeltaManifestFile(
    opts: DeltaOptions,
    inputs: RebuildInputPaths,
    imagePath, buildDir: string
): LxResult[string] =
  let hash = sha256File(imagePath)
  if hash.isErr:
    return LxResult[string].err(hash.error())

  let manifestNode = deltaManifestToJson(opts, inputs, hash.get())
  let manifestPath = buildDir / manifestFileName

  try:
    writeFile(manifestPath, manifestNode.pretty() & "\n")
  except IOError as e:
    return LxResult[string].err(ioError("failed to write delta manifest", e.msg))
  except OSError as e:
    return LxResult[string].err(ioError("failed to write delta manifest", e.msg))

  result = LxResult[string].ok(manifestPath)

proc createDeltaArchive(opts: DeltaOptions; manifestPath, imagePath: string): LxResult[void] =
  result = createArchiveWithImageName(
    manifestPath,
    imagePath,
    deltaImageFileName,
    opts.outputFile,
    opts.force,
    opts.verbose,
    store = true
  )

proc printDeltaOptions(opts: DeltaOptions; baseManifest: PackageManifest) =
  echo "lxcpkg delta options:"
  echo &"  base:            {opts.basePackageFile}"
  echo &"  dev:             {opts.devArchiveFile}"
  echo &"  output:          {opts.outputFile}"
  echo &"  packageId:       {baseManifest.packageId}"
  echo &"  name:            {baseManifest.name}"
  echo &"  baseVersion:     {baseManifest.version}"
  echo &"  version:         {opts.version}"
  echo &"  arch:            {baseManifest.arch}"
  echo &"  compression:     {opts.compression}"
  echo &"  blockSize:       {opts.blockSize}"
  echo &"  clean:           {opts.clean}"
  echo &"  scrub:           {opts.scrub}"
  echo &"  pruneEmptyDirs:  {opts.pruneEmptyDirs}"
  echo &"  force:           {opts.force}"
  echo &"  keepWorkdir:     {opts.keepWorkdir}"
  echo &"  verbose:         {opts.verbose}"

proc warnKeptDeltaDir(buildDir: string) =
  if buildDir.len == 0:
    return

  stderr.writeLine(&"Temporary delta directory was kept for inspection: {buildDir}")
  stderr.writeLine(&"Remove it manually after checking: rm -rf {buildDir}")

proc deltaPackageSteps(raw: RawDeltaOptions; buildDir: string): LxResult[void] =
  echo &"Delta directory: {buildDir}"

  let baseFile = baseValue(raw)
  if baseFile.isErr:
    return LxResult[void].err(baseFile.error())

  let devFile = devValue(raw)
  if devFile.isErr:
    return LxResult[void].err(devFile.error())

  let inputs = prepareRebuildInputs(baseFile.get(), devFile.get(), buildDir, raw.verbose)
  if inputs.isErr:
    return LxResult[void].err(inputs.error())

  let optsResult = resolveDeltaOptions(raw, inputs.get().packageManifest)
  if optsResult.isErr:
    return LxResult[void].err(optsResult.error())

  let opts = optsResult.get()
  printDeltaOptions(opts, inputs.get().packageManifest)

  let upperDir = buildDir / "upper"
  let upperCreated = createDirChecked(upperDir, "overlay upper directory")
  if upperCreated.isErr:
    return LxResult[void].err(upperCreated.error())

  let extract = extractOverlaySnapshot(inputs.get().snapshotPath, upperDir, opts.verbose)
  if extract.isErr:
    return LxResult[void].err(extract.error())

  if opts.clean:
    let cleanResult = cleanOverlayForDelta(upperDir, opts.verbose)
    if cleanResult.isErr:
      return LxResult[void].err(cleanResult.error())

  if opts.scrub:
    let scrubResult = scrubOverlayForDelta(upperDir, opts.verbose)
    if scrubResult.isErr:
      return LxResult[void].err(scrubResult.error())

  if opts.pruneEmptyDirs:
    let pruneResult = pruneEmptyDirsForDelta(upperDir, opts.verbose)
    if pruneResult.isErr:
      return LxResult[void].err(pruneResult.error())

  let imageResult = createDeltaImage(opts, upperDir, buildDir)
  if imageResult.isErr:
    return LxResult[void].err(imageResult.error())

  let manifestResult = writeDeltaManifestFile(opts, inputs.get(), imageResult.get(), buildDir)
  if manifestResult.isErr:
    return LxResult[void].err(manifestResult.error())

  let archiveResult = createDeltaArchive(opts, manifestResult.get(), imageResult.get())
  if archiveResult.isErr:
    return LxResult[void].err(archiveResult.error())

  echo &"Created delta package: {opts.outputFile}"
  result = LxResult[void].ok()

proc deltaPackage(raw: RawDeltaOptions): LxResult[void] =
  let buildDirResult = createDeltaDir()
  if buildDirResult.isErr:
    return LxResult[void].err(buildDirResult.error())

  let buildDir = buildDirResult.get()
  let deltaResult = deltaPackageSteps(raw, buildDir)

  if deltaResult.isOk:
    if raw.keepWorkdir:
      echo &"Temporary delta directory kept: {buildDir}"
      return deltaResult

    let cleanup = removeDeltaDir(buildDir)
    if cleanup.isErr:
      return cleanup

    return deltaResult

  warnKeptDeltaDir(buildDir)
  result = deltaResult

proc runDelta*(opts: RawDeltaOptions): LxResult[void] =
  result = deltaPackage(opts)
