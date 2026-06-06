# Build command entry point.
#
# This implementation resolves BuildOptions, creates rootfs.sqfs, calculates
# SHA256, generates manifest.json, and creates the final .lxcpkg archive.

import std/options
import std/os
import std/strformat
import std/strutils
import results

import accounts
import archive
import errors
import manifest
import prompts
import rootfs
import rootfs_tune
import squashfs
import types
import validation

type
  RawBuildOptions* = object
    rootfs*: Option[string]
    output*: Option[string]
    packageId*: Option[string]
    name*: Option[string]
    version*: Option[string]
    arch*: Option[string]
    rootfsMode*: Option[string]
    compression*: Option[string]
    blockSize*: Option[string]
    data*: seq[string]
    exclude*: seq[string]
    normalize*: Option[string]
    minimize*: Option[string]
    networkMode*: Option[string]
    preset*: Option[string]
    nonInteractive*: bool
    force*: bool
    verbose*: bool
    keepWorkdir*: bool

proc formatSeq(value: seq[string]): string =
  if value.len == 0:
    result = "<none>"
  else:
    result = value.join(", ")

proc optionValue(value: Option[string]; defaultValue: string): string =
  if value.isSome and value.get().len > 0:
    result = value.get()
  else:
    result = defaultValue

proc formatDataMounts(value: seq[DataMount]): string =
  if value.len == 0:
    return "<none>"

  var parts: seq[string] = @[]
  for mount in value:
    parts.add($mount)

  result = parts.join(", ")

proc rootfsValue(opts: RawBuildOptions): LxResult[string] =
  if opts.rootfs.isSome and opts.rootfs.get().len > 0:
    return LxResult[string].ok(opts.rootfs.get())

  if opts.nonInteractive:
    return LxResult[string].err(missingArgument("--rootfs"))

  result = promptRequiredString("Rootfs directory", "./rootfs")

proc nameValue(opts: RawBuildOptions): LxResult[string] =
  let name =
    if opts.name.isSome and opts.name.get().len > 0:
      LxResult[string].ok(opts.name.get())
    elif opts.nonInteractive:
      LxResult[string].err(missingArgument("--name"))
    else:
      promptRequiredString("Package name")

  if name.isErr:
    return name

  let check = validateSimpleName("package name", name.get())
  if check.isErr:
    return LxResult[string].err(check.error())

  result = name

proc outputValue(opts: RawBuildOptions; name: string): LxResult[string] =
  if opts.output.isSome and opts.output.get().len > 0:
    return LxResult[string].ok(ensureArchiveExtension(opts.output.get(), ".lxcpkg"))

  if opts.nonInteractive:
    return LxResult[string].err(missingArgument("--output"))

  let output = promptRequiredString("Output .lxcpkg file", &"{name}.lxcpkg")
  if output.isErr:
    return output

  result = LxResult[string].ok(ensureArchiveExtension(output.get(), ".lxcpkg"))

proc packageIdValue(opts: RawBuildOptions; name: string): string =
  let defaultId = defaultPackageId(name)

  if opts.packageId.isSome and opts.packageId.get().len > 0:
    result = opts.packageId.get()
  elif opts.nonInteractive:
    result = defaultId
  else:
    result = promptString("Package ID", defaultId)

proc versionValue(opts: RawBuildOptions): string =
  if opts.version.isSome and opts.version.get().len > 0:
    result = opts.version.get()
  elif opts.nonInteractive:
    result = defaultVersion
  else:
    result = promptString("Package version", defaultVersion)

proc specifiedArchValue(opts: RawBuildOptions): string =
  if opts.arch.isSome:
    result = opts.arch.get()
  else:
    result = ""

proc parseRootfsMode(text: string): LxResult[RootfsMode] =
  let value = text.strip()
  if value.len == 0:
    return LxResult[RootfsMode].ok(defaultRootfsMode)

  case value
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

proc rootfsModeValue(opts: RawBuildOptions): LxResult[RootfsMode] =
  if opts.rootfsMode.isSome:
    return parseRootfsMode(opts.rootfsMode.get())

  if opts.nonInteractive:
    return LxResult[RootfsMode].ok(defaultRootfsMode)

  result = LxResult[RootfsMode].ok(promptRootfsMode(defaultRootfsMode))

proc parseCompression(text: string): LxResult[Compression] =
  let value = text.strip()
  if value.len == 0:
    return LxResult[Compression].ok(defaultCompression)

  case value
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

proc compressionValue(opts: RawBuildOptions): LxResult[Compression] =
  if opts.compression.isSome:
    result = parseCompression(opts.compression.get())
  else:
    result = LxResult[Compression].ok(defaultCompression)

proc blockSizeValue(opts: RawBuildOptions): string =
  if opts.blockSize.isSome and opts.blockSize.get().len > 0:
    result = opts.blockSize.get()
  else:
    result = defaultBlockSize

proc dataMountSpecsValue(opts: RawBuildOptions; rootfsAccounts: RootfsAccounts): seq[string] =
  if opts.data.len > 0:
    return opts.data

  if opts.nonInteractive:
    return @[]

  result = promptDataMountSpecs(rootfsAccounts)

proc resolveBuildOptions*(opts: RawBuildOptions): LxResult[BuildOptions] =
  let rootfsDirResult = rootfsValue(opts)
  if rootfsDirResult.isErr:
    return LxResult[BuildOptions].err(rootfsDirResult.error())

  let nameResult = nameValue(opts)
  if nameResult.isErr:
    return LxResult[BuildOptions].err(nameResult.error())

  let rootfsDir = rootfsDirResult.get()
  let name = nameResult.get()

  # Resolve and check output as soon as the output file name is known. This
  # avoids asking additional interactive questions or creating squashfs when
  # the requested archive already exists.
  let outputResult = outputValue(opts, name)
  if outputResult.isErr:
    return LxResult[BuildOptions].err(outputResult.error())

  let outputCheck = checkArchiveOutput(outputResult.get(), opts.force)
  if outputCheck.isErr:
    return LxResult[BuildOptions].err(outputCheck.error())

  let packageId = packageIdValue(opts, name)
  let version = versionValue(opts)

  let rootfsModeResult = rootfsModeValue(opts)
  if rootfsModeResult.isErr:
    return LxResult[BuildOptions].err(rootfsModeResult.error())

  let archResult = resolveArchitecture(rootfsDir, specifiedArchValue(opts))
  if archResult.isErr:
    return LxResult[BuildOptions].err(archResult.error())

  let loadedAccounts = loadRootfsAccounts(rootfsDir)
  if loadedAccounts.isErr:
    return LxResult[BuildOptions].err(loadedAccounts.error())

  let dataSpecs = dataMountSpecsValue(opts, loadedAccounts.get())
  let dataMountsResult = parseDataMountSpecs(dataSpecs, loadedAccounts.get())
  if dataMountsResult.isErr:
    return LxResult[BuildOptions].err(dataMountsResult.error())

  let compressionResult = compressionValue(opts)
  if compressionResult.isErr:
    return LxResult[BuildOptions].err(compressionResult.error())

  result = LxResult[BuildOptions].ok(BuildOptions(
    rootfsDir: rootfsDir,
    outputFile: outputResult.get(),
    packageId: packageId,
    name: name,
    version: version,
    arch: archResult.get(),
    rootfsMode: rootfsModeResult.get(),
    dataMounts: dataMountsResult.get(),
    compression: compressionResult.get(),
    blockSize: blockSizeValue(opts),
    extraExcludes: opts.exclude,
    nonInteractive: opts.nonInteractive,
    force: opts.force,
    verbose: opts.verbose,
    keepWorkdir: opts.keepWorkdir
  ))

proc createBuildDir*(): LxResult[string] =
  let baseDir = getTempDir()
  let pid = getCurrentProcessId()

  for index in 0 ..< 1000:
    let path = baseDir / &"lxcpkg-{pid}-{index}"
    if dirExists(path) or fileExists(path):
      continue

    try:
      createDir(path)
      return LxResult[string].ok(path)
    except OSError as e:
      return LxResult[string].err(
        ioError("failed to create temporary build directory", e.msg)
      )

  result = LxResult[string].err(
    ioError("failed to create temporary build directory", baseDir)
  )

proc removeBuildDir(buildDir: string): LxResult[void] =
  if buildDir.len == 0:
    return LxResult[void].ok()

  try:
    removeDir(buildDir)
    result = LxResult[void].ok()
  except OSError as e:
    result = LxResult[void].err(ioError("failed to remove temporary build directory", e.msg))

proc createRootfsImage(buildOpts: BuildOptions; buildDir: string): LxResult[string] =
  let imagePath = buildDir / rootfsImageFileName
  let squashOpts = SquashfsOptions(
    sourceDir: buildOpts.rootfsDir,
    imageFile: imagePath,
    compression: buildOpts.compression,
    blockSize: buildOpts.blockSize,
    extraExcludes: buildOpts.extraExcludes,
    verbose: buildOpts.verbose
  )

  let squashResult = makeSquashfs(squashOpts)
  if squashResult.isErr:
    return LxResult[string].err(squashResult.error())

  result = LxResult[string].ok(imagePath)

proc createManifestFile(buildOpts: BuildOptions; imagePath, buildDir: string): LxResult[string] =
  let hash = sha256File(imagePath)
  if hash.isErr:
    return LxResult[string].err(hash.error())

  let pkgManifest = makeManifest(buildOpts, hash.get())
  let manifestPath = buildDir / manifestFileName
  let writeResult = writeManifest(pkgManifest, manifestPath)
  if writeResult.isErr:
    return LxResult[string].err(writeResult.error())

  result = LxResult[string].ok(manifestPath)

proc createPackageArchive(buildOpts: BuildOptions; manifestPath, imagePath: string): LxResult[void] =
  let archiveOpts = ArchiveOptions(
    manifestFile: manifestPath,
    imageFile: imagePath,
    outputFile: buildOpts.outputFile,
    force: buildOpts.force,
    verbose: buildOpts.verbose
  )

  result = createArchive(archiveOpts)

proc printResolvedOptions(buildOpts: BuildOptions; rawData: seq[string]) =
  let dataText = formatSeq(rawData)
  let resolvedDataText = formatDataMounts(buildOpts.dataMounts)
  let excludeText = formatSeq(buildOpts.extraExcludes)

  echo "lxcpkg build options:"
  echo &"  rootfs:          {buildOpts.rootfsDir}"
  echo &"  output:          {buildOpts.outputFile}"
  echo &"  packageId:       {buildOpts.packageId}"
  echo &"  name:            {buildOpts.name}"
  echo &"  version:         {buildOpts.version}"
  echo &"  arch:            {buildOpts.arch}"
  echo &"  rootfsMode:      {buildOpts.rootfsMode}"
  echo &"  compression:     {buildOpts.compression}"
  echo &"  blockSize:       {buildOpts.blockSize}"
  echo &"  data:            {dataText}"
  echo &"  resolvedData:    {resolvedDataText}"
  echo &"  exclude:         {excludeText}"
  echo &"  nonInteractive:  {buildOpts.nonInteractive}"
  echo &"  force:           {buildOpts.force}"
  echo &"  keepWorkdir:     {buildOpts.keepWorkdir}"
  echo &"  verbose:         {buildOpts.verbose}"

proc warnKeptBuildDir(buildDir: string) =
  if buildDir.len == 0:
    return

  stderr.writeLine(&"Temporary build directory was kept for inspection: {buildDir}")
  stderr.writeLine(&"Remove it manually after checking: rm -rf {buildDir}")

proc buildPackageSteps(buildOpts: BuildOptions; buildDir: string): LxResult[void] =
  echo &"Build directory: {buildDir}"

  let imageResult = createRootfsImage(buildOpts, buildDir)
  if imageResult.isErr:
    return LxResult[void].err(imageResult.error())

  let imagePath = imageResult.get()
  echo &"Created rootfs image: {imagePath}"

  let manifestResult = createManifestFile(buildOpts, imagePath, buildDir)
  if manifestResult.isErr:
    return LxResult[void].err(manifestResult.error())

  let manifestPath = manifestResult.get()
  echo &"Created manifest: {manifestPath}"

  let archiveResult = createPackageArchive(buildOpts, manifestPath, imagePath)
  if archiveResult.isErr:
    return LxResult[void].err(archiveResult.error())

  echo &"Created package: {buildOpts.outputFile}"
  result = LxResult[void].ok()

proc buildPackage(buildOpts: BuildOptions): LxResult[void] =
  let outputCheck = checkArchiveOutput(buildOpts.outputFile, buildOpts.force)
  if outputCheck.isErr:
    return outputCheck

  let buildDirResult = createBuildDir()
  if buildDirResult.isErr:
    return LxResult[void].err(buildDirResult.error())

  let buildDir = buildDirResult.get()
  let buildResult = buildPackageSteps(buildOpts, buildDir)

  if buildResult.isOk:
    if buildOpts.keepWorkdir:
      echo &"Temporary build directory kept: {buildDir}"
      return buildResult

    let cleanup = removeBuildDir(buildDir)
    if cleanup.isErr:
      return cleanup

    return buildResult

  warnKeptBuildDir(buildDir)
  result = buildResult

proc applyRequestedRootfsProfiles(opts: RawBuildOptions; rootfsDir: string): LxResult[void] =
  let profiles = resolveRootfsProfileSelection(
    optionValue(opts.preset, "none"),
    optionValue(opts.normalize, "none"),
    optionValue(opts.minimize, "none"),
    optionValue(opts.networkMode, "dhcp")
  )
  if profiles.isErr:
    return LxResult[void].err(profiles.error())

  let (normalize, minimize, networkMode) = profiles.get()
  result = applyRootfsProfiles(rootfsDir, normalize, minimize, networkMode, opts.verbose)

proc runBuild*(opts: RawBuildOptions): LxResult[void] =
  let resolved = resolveBuildOptions(opts)
  if resolved.isErr:
    return LxResult[void].err(resolved.error())

  let buildOpts = resolved.get()
  printResolvedOptions(buildOpts, opts.data)

  let tuned = applyRequestedRootfsProfiles(opts, buildOpts.rootfsDir)
  if tuned.isErr:
    return LxResult[void].err(tuned.error())

  result = buildPackage(buildOpts)
