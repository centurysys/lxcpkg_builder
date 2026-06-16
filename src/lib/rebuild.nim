# Rebuild support for lxcpkg.
#
# This module rebuilds a .lxcpkg package from a base .lxcpkg package and a
# .lxcdev development archive. The development archive contains an overlayfs
# upperdir snapshot; rebuild uses overlayfs to produce a merged rootfs view so
# whiteouts and opaque directories are handled by the kernel rather than by a
# lossy copy step.

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
import devarchive
import errors
import manifest
import squashfs
import types

const
  defaultRebuildCompression = compZstd
  defaultRebuildBlockSize = defaultBlockSize

type
  RawRebuildOptions* = object
    base*: Option[string]
    dev*: Option[string]
    output*: Option[string]
    version*: Option[string]
    rootfsMode*: Option[string]
    compression*: Option[string]
    blockSize*: Option[string]
    exclude*: seq[string]
    clean*: bool
    scrub*: bool
    pruneEmptyDirs*: bool
    force*: bool
    verbose*: bool
    keepWorkdir*: bool

  RebuildOptions* = object
    basePackageFile*: string
    devArchiveFile*: string
    outputFile*: string
    version*: string
    rootfsMode*: RootfsMode
    compression*: Compression
    blockSize*: string
    extraExcludes*: seq[string]
    clean*: bool
    scrub*: bool
    pruneEmptyDirs*: bool
    force*: bool
    verbose*: bool
    keepWorkdir*: bool

  MountedRebuildRootfs = object
    baseMountDir: string
    upperDir: string
    overlayWorkDir: string
    mergedDir: string
    baseMounted: bool
    overlayMounted: bool

proc invalidRebuildInput(message: string; detail = ""): LxError =
  result = newError(ekInvalidManifest, message, detail)

proc isSafeRelativeArchivePath(path: string): bool =
  let normalized = path.replace('\\', '/')
  if normalized.len == 0:
    return false

  if normalized.startsWith("/"):
    return false

  for part in normalized.split('/'):
    if part.len == 0 or part == "." or part == "..":
      return false

  result = true

proc checkedArchivePath(baseDir, archivePath, description: string): LxResult[string] =
  if not isSafeRelativeArchivePath(archivePath):
    return LxResult[string].err(
      invalidRebuildInput(&"unsafe {description} path", archivePath)
    )

  result = LxResult[string].ok(baseDir / archivePath)

proc verifyFileSha256(path, expectedSha256, description: string): LxResult[void] =
  if not fileExists(path):
    return LxResult[void].err(ioError(&"{description} does not exist", path))

  let actual = sha256File(path)
  if actual.isErr:
    return LxResult[void].err(actual.error())

  if actual.get().toLowerAscii() != expectedSha256.toLowerAscii():
    return LxResult[void].err(
      invalidRebuildInput(
        &"{description} SHA256 mismatch",
        &"expected={expectedSha256}, actual={actual.get()}"
      )
    )

  result = LxResult[void].ok()

proc verifyManifestCompatibility(
    packageManifest: PackageManifest,
    devManifest: DevArchiveManifest
): LxResult[void] =
  if devManifest.dataMountsIncluded:
    return LxResult[void].err(
      invalidRebuildInput("lxcdev archives with data mounts are not supported yet")
    )

  if packageManifest.name != devManifest.packageName:
    return LxResult[void].err(
      invalidRebuildInput(
        "package name mismatch",
        &"base={packageManifest.name}, lxcdev={devManifest.packageName}"
      )
    )

  if packageManifest.version != devManifest.version:
    return LxResult[void].err(
      invalidRebuildInput(
        "package version mismatch",
        &"base={packageManifest.version}, lxcdev={devManifest.version}"
      )
    )

  if packageManifest.arch != devManifest.arch:
    return LxResult[void].err(
      invalidRebuildInput(
        "package architecture mismatch",
        &"base={packageManifest.arch}, lxcdev={devManifest.arch}"
      )
    )

  if packageManifest.image.file != devManifest.base.imageFile:
    return LxResult[void].err(
      invalidRebuildInput(
        "base image file mismatch",
        &"base={packageManifest.image.file}, lxcdev={devManifest.base.imageFile}"
      )
    )

  if packageManifest.image.sha256.toLowerAscii() != devManifest.base.imageSha256.toLowerAscii():
    return LxResult[void].err(
      invalidRebuildInput(
        "base image SHA256 mismatch",
        &"base={packageManifest.image.sha256}, lxcdev={devManifest.base.imageSha256}"
      )
    )

  result = LxResult[void].ok()

proc prepareRebuildInputs*(
    basePackageFile, devArchiveFile, workDir: string,
    verbose = false
): LxResult[RebuildInputPaths] =
  if basePackageFile.len == 0:
    return LxResult[RebuildInputPaths].err(missingArgument("--base"))

  if devArchiveFile.len == 0:
    return LxResult[RebuildInputPaths].err(missingArgument("--dev"))

  if workDir.len == 0:
    return LxResult[RebuildInputPaths].err(invalidArgument("work directory must not be empty"))

  let baseDir = workDir / "base"
  let devDir = workDir / "dev"

  let extractBase = extractZipArchive(basePackageFile, baseDir, verbose)
  if extractBase.isErr:
    return LxResult[RebuildInputPaths].err(extractBase.error())

  let extractDev = extractZipArchive(devArchiveFile, devDir, verbose)
  if extractDev.isErr:
    return LxResult[RebuildInputPaths].err(extractDev.error())

  let baseManifestPath = baseDir / manifestFileName
  let packageManifest = readManifest(baseManifestPath)
  if packageManifest.isErr:
    return LxResult[RebuildInputPaths].err(packageManifest.error())

  let devManifestPath = devDir / lxcDevArchiveManifestFileName
  let devManifest = readDevArchiveManifest(devManifestPath)
  if devManifest.isErr:
    return LxResult[RebuildInputPaths].err(devManifest.error())

  let compatibility = verifyManifestCompatibility(packageManifest.get(), devManifest.get())
  if compatibility.isErr:
    return LxResult[RebuildInputPaths].err(compatibility.error())

  let baseImagePath = checkedArchivePath(baseDir, packageManifest.get().image.file, "base image")
  if baseImagePath.isErr:
    return LxResult[RebuildInputPaths].err(baseImagePath.error())

  let baseHash = verifyFileSha256(
    baseImagePath.get(),
    packageManifest.get().image.sha256,
    "base image"
  )
  if baseHash.isErr:
    return LxResult[RebuildInputPaths].err(baseHash.error())

  let snapshotPath = checkedArchivePath(devDir, devManifest.get().snapshot.file, "snapshot")
  if snapshotPath.isErr:
    return LxResult[RebuildInputPaths].err(snapshotPath.error())

  let snapshotHash = verifyFileSha256(
    snapshotPath.get(),
    devManifest.get().snapshot.sha256,
    "overlay snapshot"
  )
  if snapshotHash.isErr:
    return LxResult[RebuildInputPaths].err(snapshotHash.error())

  result = LxResult[RebuildInputPaths].ok(RebuildInputPaths(
    baseDir: baseDir,
    devDir: devDir,
    baseManifestPath: baseManifestPath,
    baseImagePath: baseImagePath.get(),
    devManifestPath: devManifestPath,
    snapshotPath: snapshotPath.get(),
    packageManifest: packageManifest.get(),
    devManifest: devManifest.get()
  ))

proc isSemverCore(version: string): bool =
  let parts = version.split('.')
  if parts.len != 3:
    return false

  for part in parts:
    if part.len == 0:
      return false

    for ch in part:
      if ch < '0' or ch > '9':
        return false

  result = true

proc rebuildTimestampUtc(): string =
  let dt = getTime().utc()
  result = dt.format("yyyyMMdd.HHmm")

proc deriveRebuildVersion*(baseVersion: string): string =
  if isSemverCore(baseVersion):
    result = &"{baseVersion}+lxcdev.{rebuildTimestampUtc()}"
  else:
    result = baseVersion

proc parseRootfsMode(text: string): LxResult[RootfsMode] =
  case text.strip()
  of "persistent":
    result = LxResult[RootfsMode].ok(rmPersistent)
  of "volatile":
    result = LxResult[RootfsMode].ok(rmVolatile)
  of "snapshot":
    result = LxResult[RootfsMode].ok(rmSnapshot)
  else:
    result = LxResult[RootfsMode].err(
      invalidArgument(
        "invalid rootfs mode",
        "allowed values: persistent, volatile, snapshot"
      )
    )

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

proc baseValue(opts: RawRebuildOptions): LxResult[string] =
  if opts.base.isSome and opts.base.get().len > 0:
    return LxResult[string].ok(opts.base.get())

  result = LxResult[string].err(missingArgument("--base"))

proc devValue(opts: RawRebuildOptions): LxResult[string] =
  if opts.dev.isSome and opts.dev.get().len > 0:
    return LxResult[string].ok(opts.dev.get())

  result = LxResult[string].err(missingArgument("--dev"))

proc outputValue(opts: RawRebuildOptions; manifest: PackageManifest; version: string): string =
  if opts.output.isSome and opts.output.get().len > 0:
    return ensureArchiveExtension(opts.output.get(), ".lxcpkg")

  result = ensureArchiveExtension(&"{manifest.name}-{version}", ".lxcpkg")

proc versionValue(opts: RawRebuildOptions; baseVersion: string): string =
  if opts.version.isSome and opts.version.get().len > 0:
    return opts.version.get()

  result = deriveRebuildVersion(baseVersion)
  if result == baseVersion:
    stderr.writeLine(&"warning: base version is not MAJOR.MINOR.PATCH; keeping version unchanged: {baseVersion}")

proc rootfsModeValue(opts: RawRebuildOptions; baseMode: RootfsMode): LxResult[RootfsMode] =
  if opts.rootfsMode.isSome:
    return parseRootfsMode(opts.rootfsMode.get())

  result = LxResult[RootfsMode].ok(baseMode)

proc compressionValue(opts: RawRebuildOptions): LxResult[Compression] =
  if opts.compression.isSome:
    return parseCompression(opts.compression.get())

  result = LxResult[Compression].ok(defaultRebuildCompression)

proc blockSizeValue(opts: RawRebuildOptions): string =
  if opts.blockSize.isSome and opts.blockSize.get().len > 0:
    result = opts.blockSize.get()
  else:
    result = defaultRebuildBlockSize

proc resolveRebuildOptions*(
    opts: RawRebuildOptions,
    manifest: PackageManifest
): LxResult[RebuildOptions] =
  let baseResult = baseValue(opts)
  if baseResult.isErr:
    return LxResult[RebuildOptions].err(baseResult.error())

  let devResult = devValue(opts)
  if devResult.isErr:
    return LxResult[RebuildOptions].err(devResult.error())

  let version = versionValue(opts, manifest.version)

  let modeResult = rootfsModeValue(opts, manifest.rootfsMode)
  if modeResult.isErr:
    return LxResult[RebuildOptions].err(modeResult.error())

  let compressionResult = compressionValue(opts)
  if compressionResult.isErr:
    return LxResult[RebuildOptions].err(compressionResult.error())

  let output = outputValue(opts, manifest, version)
  let outputCheck = checkArchiveOutput(output, opts.force)
  if outputCheck.isErr:
    return LxResult[RebuildOptions].err(outputCheck.error())

  result = LxResult[RebuildOptions].ok(RebuildOptions(
    basePackageFile: baseResult.get(),
    devArchiveFile: devResult.get(),
    outputFile: output,
    version: version,
    rootfsMode: modeResult.get(),
    compression: compressionResult.get(),
    blockSize: blockSizeValue(opts),
    extraExcludes: opts.exclude,
    clean: opts.clean,
    scrub: opts.scrub,
    pruneEmptyDirs: opts.pruneEmptyDirs,
    force: opts.force,
    verbose: opts.verbose,
    keepWorkdir: opts.keepWorkdir
  ))

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

proc createRebuildDir(): LxResult[string] =
  let baseDir = getTempDir()
  let pid = getCurrentProcessId()

  for index in 0 ..< 1000:
    let path = baseDir / &"lxcpkg-rebuild-{pid}-{index}"
    if dirExists(path) or fileExists(path):
      continue

    try:
      createDir(path)
      return LxResult[string].ok(path)
    except OSError as e:
      return LxResult[string].err(
        ioError("failed to create temporary rebuild directory", e.msg)
      )

  result = LxResult[string].err(
    ioError("failed to create temporary rebuild directory", baseDir)
  )

proc removeRebuildDir(buildDir: string): LxResult[void] =
  if buildDir.len == 0:
    return LxResult[void].ok()

  try:
    removeDir(buildDir)
    result = LxResult[void].ok()
  except OSError as e:
    result = LxResult[void].err(ioError("failed to remove temporary rebuild directory", e.msg))

proc createDirChecked(path, description: string): LxResult[void] =
  try:
    createDir(path)
    result = LxResult[void].ok()
  except OSError as e:
    result = LxResult[void].err(ioError(&"failed to create {description}", e.msg))

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

proc mountSquashfs(imagePath, mountDir: string; verbose: bool): LxResult[void] =
  let tool = findTool("mount")
  if tool.isErr:
    return LxResult[void].err(tool.error())

  let args = @[
    "-t",
    "squashfs",
    "-o",
    "loop,ro",
    imagePath,
    mountDir
  ]

  result = runCommand(tool.get(), args, getCurrentDir(), verbose)

proc mountOverlayRootfs(paths: MountedRebuildRootfs; verbose: bool): LxResult[void] =
  let tool = findTool("mount")
  if tool.isErr:
    return LxResult[void].err(tool.error())

  let overlayOpts = &"lowerdir={paths.baseMountDir},upperdir={paths.upperDir},workdir={paths.overlayWorkDir}"
  let args = @[
    "-t",
    "overlay",
    "overlay",
    "-o",
    overlayOpts,
    paths.mergedDir
  ]

  result = runCommand(tool.get(), args, getCurrentDir(), verbose)

proc umountPath(path: string; verbose: bool): LxResult[void] =
  let tool = findTool("umount")
  if tool.isErr:
    return LxResult[void].err(tool.error())

  result = runCommand(tool.get(), @[path], getCurrentDir(), verbose)

proc cleanupMergedRootfs(paths: MountedRebuildRootfs; verbose: bool): LxResult[void] =
  if paths.overlayMounted:
    let overlayUmount = umountPath(paths.mergedDir, verbose)
    if overlayUmount.isErr:
      return overlayUmount

  if paths.baseMounted:
    let baseUmount = umountPath(paths.baseMountDir, verbose)
    if baseUmount.isErr:
      return baseUmount

  result = LxResult[void].ok()

proc setupMergedRootfs(
    inputs: RebuildInputPaths,
    workDir: string,
    verbose: bool
): LxResult[MountedRebuildRootfs] =
  var paths = MountedRebuildRootfs(
    baseMountDir: workDir / "base-rootfs",
    upperDir: workDir / "upper",
    overlayWorkDir: workDir / "overlay-work",
    mergedDir: workDir / "merged-rootfs",
    baseMounted: false,
    overlayMounted: false
  )

  let baseDirCreated = createDirChecked(paths.baseMountDir, "base rootfs mount directory")
  if baseDirCreated.isErr:
    return LxResult[MountedRebuildRootfs].err(baseDirCreated.error())

  let upperDirCreated = createDirChecked(paths.upperDir, "overlay upper directory")
  if upperDirCreated.isErr:
    return LxResult[MountedRebuildRootfs].err(upperDirCreated.error())

  let overlayWorkDirCreated = createDirChecked(paths.overlayWorkDir, "overlay work directory")
  if overlayWorkDirCreated.isErr:
    return LxResult[MountedRebuildRootfs].err(overlayWorkDirCreated.error())

  let mergedDirCreated = createDirChecked(paths.mergedDir, "merged rootfs directory")
  if mergedDirCreated.isErr:
    return LxResult[MountedRebuildRootfs].err(mergedDirCreated.error())

  let baseMount = mountSquashfs(inputs.baseImagePath, paths.baseMountDir, verbose)
  if baseMount.isErr:
    return LxResult[MountedRebuildRootfs].err(baseMount.error())
  paths.baseMounted = true

  let extract = extractOverlaySnapshot(inputs.snapshotPath, paths.upperDir, verbose)
  if extract.isErr:
    let cleanup = cleanupMergedRootfs(paths, verbose)
    if cleanup.isErr:
      return LxResult[MountedRebuildRootfs].err(cleanup.error())
    return LxResult[MountedRebuildRootfs].err(extract.error())

  let overlayMount = mountOverlayRootfs(paths, verbose)
  if overlayMount.isErr:
    let cleanup = cleanupMergedRootfs(paths, verbose)
    if cleanup.isErr:
      return LxResult[MountedRebuildRootfs].err(cleanup.error())
    return LxResult[MountedRebuildRootfs].err(overlayMount.error())
  paths.overlayMounted = true

  result = LxResult[MountedRebuildRootfs].ok(paths)

proc releaseCleanMergedRootfs(opts: RebuildOptions; mergedDir: string): LxResult[void] =
  if opts.clean:
    let cleanResult = cleanRootfsForPackage(mergedDir, opts.verbose)
    if cleanResult.isErr:
      return cleanResult

  if opts.scrub:
    let scrubResult = scrubRootfsForPackage(mergedDir, opts.verbose)
    if scrubResult.isErr:
      return scrubResult

  if opts.pruneEmptyDirs:
    let pruneResult = pruneEmptyDirsForPackage(mergedDir, opts.verbose)
    if pruneResult.isErr:
      return pruneResult

  result = LxResult[void].ok()

proc createRebuiltRootfsImage(
    opts: RebuildOptions,
    mergedDir, buildDir: string
): LxResult[string] =
  let imagePath = buildDir / rootfsImageFileName
  let squashOpts = SquashfsOptions(
    sourceDir: mergedDir,
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

proc createRebuiltManifestFile(
    opts: RebuildOptions,
    inputs: RebuildInputPaths,
    imagePath, buildDir: string
): LxResult[string] =
  let hash = sha256File(imagePath)
  if hash.isErr:
    return LxResult[string].err(hash.error())

  let manifest = PackageManifest(
    packageId: inputs.packageManifest.packageId,
    name: inputs.packageManifest.name,
    version: opts.version,
    arch: inputs.packageManifest.arch,
    rootfsMode: opts.rootfsMode,
    image: ImageInfo(
      file: rootfsImageFileName,
      sha256: hash.get()
    ),
    dataMounts: inputs.packageManifest.dataMounts
  )

  let manifestPath = buildDir / manifestFileName
  let writeResult = writeManifest(manifest, manifestPath)
  if writeResult.isErr:
    return LxResult[string].err(writeResult.error())

  result = LxResult[string].ok(manifestPath)

proc createRebuiltArchive(opts: RebuildOptions; manifestPath, imagePath: string): LxResult[void] =
  let archiveOpts = ArchiveOptions(
    manifestFile: manifestPath,
    imageFile: imagePath,
    outputFile: opts.outputFile,
    force: opts.force,
    verbose: opts.verbose
  )

  result = createArchive(archiveOpts)

proc printRebuildOptions(opts: RebuildOptions; baseManifest: PackageManifest) =
  echo "lxcpkg rebuild options:"
  echo &"  base:            {opts.basePackageFile}"
  echo &"  dev:             {opts.devArchiveFile}"
  echo &"  output:          {opts.outputFile}"
  echo &"  packageId:       {baseManifest.packageId}"
  echo &"  name:            {baseManifest.name}"
  echo &"  baseVersion:     {baseManifest.version}"
  echo &"  version:         {opts.version}"
  echo &"  arch:            {baseManifest.arch}"
  echo &"  rootfsMode:      {opts.rootfsMode}"
  echo &"  compression:     {opts.compression}"
  echo &"  blockSize:       {opts.blockSize}"
  echo &"  clean:           {opts.clean}"
  echo &"  scrub:           {opts.scrub}"
  echo &"  pruneEmptyDirs:  {opts.pruneEmptyDirs}"
  echo &"  force:           {opts.force}"
  echo &"  keepWorkdir:     {opts.keepWorkdir}"
  echo &"  verbose:         {opts.verbose}"

proc warnKeptRebuildDir(buildDir: string) =
  if buildDir.len == 0:
    return

  stderr.writeLine(&"Temporary rebuild directory was kept for inspection: {buildDir}")
  stderr.writeLine(&"Remove it manually after checking: rm -rf {buildDir}")

proc rebuildPackageSteps(raw: RawRebuildOptions; buildDir: string): LxResult[void] =
  echo &"Rebuild directory: {buildDir}"

  let baseFile = baseValue(raw)
  if baseFile.isErr:
    return LxResult[void].err(baseFile.error())

  let devFile = devValue(raw)
  if devFile.isErr:
    return LxResult[void].err(devFile.error())

  let inputs = prepareRebuildInputs(baseFile.get(), devFile.get(), buildDir, raw.verbose)
  if inputs.isErr:
    return LxResult[void].err(inputs.error())

  let optsResult = resolveRebuildOptions(raw, inputs.get().packageManifest)
  if optsResult.isErr:
    return LxResult[void].err(optsResult.error())

  let opts = optsResult.get()
  printRebuildOptions(opts, inputs.get().packageManifest)

  let merged = setupMergedRootfs(inputs.get(), buildDir, opts.verbose)
  if merged.isErr:
    return LxResult[void].err(merged.error())

  var cleanupResult = LxResult[void].ok()
  let mergedPaths = merged.get()

  let releaseCleanResult = releaseCleanMergedRootfs(opts, mergedPaths.mergedDir)
  if releaseCleanResult.isErr:
    cleanupResult = cleanupMergedRootfs(mergedPaths, opts.verbose)
    if cleanupResult.isErr:
      return cleanupResult
    return LxResult[void].err(releaseCleanResult.error())

  let imageResult = createRebuiltRootfsImage(opts, mergedPaths.mergedDir, buildDir)
  if imageResult.isErr:
    cleanupResult = cleanupMergedRootfs(mergedPaths, opts.verbose)
    if cleanupResult.isErr:
      return cleanupResult
    return LxResult[void].err(imageResult.error())

  let manifestResult = createRebuiltManifestFile(opts, inputs.get(), imageResult.get(), buildDir)
  if manifestResult.isErr:
    cleanupResult = cleanupMergedRootfs(mergedPaths, opts.verbose)
    if cleanupResult.isErr:
      return cleanupResult
    return LxResult[void].err(manifestResult.error())

  let archiveResult = createRebuiltArchive(opts, manifestResult.get(), imageResult.get())
  cleanupResult = cleanupMergedRootfs(mergedPaths, opts.verbose)
  if cleanupResult.isErr:
    return cleanupResult

  if archiveResult.isErr:
    return LxResult[void].err(archiveResult.error())

  echo &"Created package: {opts.outputFile}"
  result = LxResult[void].ok()

proc rebuildPackage(raw: RawRebuildOptions): LxResult[void] =
  let buildDirResult = createRebuildDir()
  if buildDirResult.isErr:
    return LxResult[void].err(buildDirResult.error())

  let buildDir = buildDirResult.get()
  let rebuildResult = rebuildPackageSteps(raw, buildDir)

  if rebuildResult.isOk:
    if raw.keepWorkdir:
      echo &"Temporary rebuild directory kept: {buildDir}"
      return rebuildResult

    let cleanup = removeRebuildDir(buildDir)
    if cleanup.isErr:
      return cleanup

    return rebuildResult

  warnKeptRebuildDir(buildDir)
  result = rebuildResult

proc runRebuild*(opts: RawRebuildOptions): LxResult[void] =
  result = rebuildPackage(opts)
