# Metadata rewrite support for lxcpkg.
#
# This module rewrites manifest metadata in an existing .lxcpkg archive without
# rebuilding rootfs.sqfs. It is intended for creating a new package lineage from
# an existing base package before uploading/installing it as a new appliance.

import std/options
import std/os
import std/strformat
import std/strutils

import results

import archive
import errors
import manifest
import types
import validation

type
  RawRewriteMetadataOptions* = object
    input*: Option[string]
    output*: Option[string]
    packageId*: Option[string]
    name*: Option[string]
    version*: Option[string]
    force*: bool
    verbose*: bool
    keepWorkdir*: bool

  RewriteMetadataOptions* = object
    inputFile*: string
    outputFile*: string
    packageId*: string
    name*: string
    version*: string
    force*: bool
    verbose*: bool
    keepWorkdir*: bool

proc invalidRewriteInput(message: string; detail = ""): LxError =
  result = newError(ekInvalidManifest, message, detail)

proc inputValue(opts: RawRewriteMetadataOptions): LxResult[string] =
  if opts.input.isSome and opts.input.get().len > 0:
    return LxResult[string].ok(opts.input.get())

  result = LxResult[string].err(missingArgument("--input"))

proc outputValue(opts: RawRewriteMetadataOptions): LxResult[string] =
  if opts.output.isSome and opts.output.get().len > 0:
    return LxResult[string].ok(ensureArchiveExtension(opts.output.get(), ".lxcpkg"))

  result = LxResult[string].err(missingArgument("--output"))

proc isSamePath(a, b: string): bool =
  result = absolutePath(a).normalizedPath() == absolutePath(b).normalizedPath()

proc hasMetadataChange(opts: RawRewriteMetadataOptions): bool =
  result = opts.packageId.isSome or opts.name.isSome or opts.version.isSome

proc nonEmptyOptionValue(kind: string; value: Option[string]): LxResult[string] =
  if value.isNone:
    return LxResult[string].ok("")

  let text = value.get().strip()
  if text.len == 0:
    return LxResult[string].err(invalidArgument(&"{kind} must not be empty"))

  result = LxResult[string].ok(text)

proc validatePackageId(packageId: string): LxResult[void] =
  result = validateSimpleName("package ID", packageId)

proc validatePackageName(name: string): LxResult[void] =
  result = validateSimpleName("package name", name)

proc validateVersion(version: string): LxResult[void] =
  if version.len == 0:
    return LxResult[void].err(invalidArgument("package version must not be empty"))

  for c in version:
    if c <= ' ' or c == '/' or c == '\\':
      return LxResult[void].err(
        invalidArgument(
          "invalid package version",
          &"{version}: whitespace, '/', and '\\' are not allowed"
        )
      )

  result = LxResult[void].ok()

proc resolveRewriteMetadataOptions*(
    opts: RawRewriteMetadataOptions,
    manifest: PackageManifest
): LxResult[RewriteMetadataOptions] =
  let inputResult = inputValue(opts)
  if inputResult.isErr:
    return LxResult[RewriteMetadataOptions].err(inputResult.error())

  let outputResult = outputValue(opts)
  if outputResult.isErr:
    return LxResult[RewriteMetadataOptions].err(outputResult.error())

  let inputFile = inputResult.get()
  let outputFile = outputResult.get()

  if not fileExists(inputFile):
    return LxResult[RewriteMetadataOptions].err(ioError("input .lxcpkg does not exist", inputFile))

  if isSamePath(inputFile, outputFile):
    return LxResult[RewriteMetadataOptions].err(
      invalidArgument(
        "in-place metadata rewrite is not supported",
        "use a different --output path"
      )
    )

  if not hasMetadataChange(opts):
    return LxResult[RewriteMetadataOptions].err(
      invalidArgument("at least one of --package-id, --name, or --version is required")
    )

  let packageIdInput = nonEmptyOptionValue("package ID", opts.packageId)
  if packageIdInput.isErr:
    return LxResult[RewriteMetadataOptions].err(packageIdInput.error())

  let nameInput = nonEmptyOptionValue("package name", opts.name)
  if nameInput.isErr:
    return LxResult[RewriteMetadataOptions].err(nameInput.error())

  let versionInput = nonEmptyOptionValue("package version", opts.version)
  if versionInput.isErr:
    return LxResult[RewriteMetadataOptions].err(versionInput.error())

  let packageId =
    if opts.packageId.isSome: packageIdInput.get() else: manifest.packageId
  let name =
    if opts.name.isSome: nameInput.get() else: manifest.name
  let version =
    if opts.version.isSome: versionInput.get() else: manifest.version

  let packageIdCheck = validatePackageId(packageId)
  if packageIdCheck.isErr:
    return LxResult[RewriteMetadataOptions].err(packageIdCheck.error())

  let nameCheck = validatePackageName(name)
  if nameCheck.isErr:
    return LxResult[RewriteMetadataOptions].err(nameCheck.error())

  let versionCheck = validateVersion(version)
  if versionCheck.isErr:
    return LxResult[RewriteMetadataOptions].err(versionCheck.error())

  let outputCheck = checkArchiveOutput(outputFile, opts.force)
  if outputCheck.isErr:
    return LxResult[RewriteMetadataOptions].err(outputCheck.error())

  result = LxResult[RewriteMetadataOptions].ok(RewriteMetadataOptions(
    inputFile: inputFile,
    outputFile: outputFile,
    packageId: packageId,
    name: name,
    version: version,
    force: opts.force,
    verbose: opts.verbose,
    keepWorkdir: opts.keepWorkdir
  ))

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
      invalidRewriteInput(&"unsafe {description} path", archivePath)
    )

  result = LxResult[string].ok(baseDir / archivePath)

proc verifyImageFile(manifest: PackageManifest; packageDir: string): LxResult[string] =
  let imagePath = checkedArchivePath(packageDir, manifest.image.file, "image")
  if imagePath.isErr:
    return LxResult[string].err(imagePath.error())

  if not fileExists(imagePath.get()):
    return LxResult[string].err(ioError("image file does not exist in .lxcpkg", manifest.image.file))

  let actualSha256 = sha256File(imagePath.get())
  if actualSha256.isErr:
    return LxResult[string].err(actualSha256.error())

  if actualSha256.get().toLowerAscii() != manifest.image.sha256.toLowerAscii():
    return LxResult[string].err(
      invalidRewriteInput(
        "image SHA256 mismatch",
        &"expected={manifest.image.sha256}, actual={actualSha256.get()}"
      )
    )

  result = LxResult[string].ok(imagePath.get())

proc createRewriteMetadataDir(): LxResult[string] =
  let baseDir = getTempDir()
  let pid = getCurrentProcessId()

  for index in 0 ..< 1000:
    let path = baseDir / &"lxcpkg-rewrite-metadata-{pid}-{index}"
    if dirExists(path) or fileExists(path):
      continue

    try:
      createDir(path)
      return LxResult[string].ok(path)
    except OSError as e:
      return LxResult[string].err(
        ioError("failed to create temporary rewrite-metadata directory", e.msg)
      )

  result = LxResult[string].err(
    ioError("failed to create temporary rewrite-metadata directory", baseDir)
  )

proc removeRewriteMetadataDir(buildDir: string): LxResult[void] =
  if buildDir.len == 0:
    return LxResult[void].ok()

  try:
    removeDir(buildDir)
    result = LxResult[void].ok()
  except OSError as e:
    result = LxResult[void].err(
      ioError("failed to remove temporary rewrite-metadata directory", e.msg)
    )

proc rewriteManifest(manifest: PackageManifest; opts: RewriteMetadataOptions): PackageManifest =
  result = manifest
  result.packageId = opts.packageId
  result.name = opts.name
  result.version = opts.version

proc printRewriteMetadataOptions(opts: RewriteMetadataOptions; original: PackageManifest) =
  echo "lxcpkg rewrite-metadata options:"
  echo &"  input:           {opts.inputFile}"
  echo &"  output:          {opts.outputFile}"
  echo &"  oldPackageId:    {original.packageId}"
  echo &"  packageId:       {opts.packageId}"
  echo &"  oldName:         {original.name}"
  echo &"  name:            {opts.name}"
  echo &"  oldVersion:      {original.version}"
  echo &"  version:         {opts.version}"
  echo &"  arch:            {original.arch}"
  echo &"  rootfsMode:      {original.rootfsMode}"
  echo &"  image:           {original.image.file}"
  echo &"  imageSha256:     {original.image.sha256}"
  echo &"  force:           {opts.force}"
  echo &"  keepWorkdir:     {opts.keepWorkdir}"
  echo &"  verbose:         {opts.verbose}"

proc warnKeptRewriteMetadataDir(buildDir: string) =
  if buildDir.len == 0:
    return

  stderr.writeLine(&"Temporary rewrite-metadata directory was kept for inspection: {buildDir}")
  stderr.writeLine(&"Remove it manually after checking: rm -rf {buildDir}")

proc rewriteMetadataSteps(raw: RawRewriteMetadataOptions; buildDir: string): LxResult[void] =
  if raw.verbose:
    echo &"Rewrite-metadata directory: {buildDir}"

  let inputFile = inputValue(raw)
  if inputFile.isErr:
    return LxResult[void].err(inputFile.error())

  if not fileExists(inputFile.get()):
    return LxResult[void].err(ioError("input .lxcpkg does not exist", inputFile.get()))

  let packageDir = buildDir / "package"
  let extracted = extractZipArchive(inputFile.get(), packageDir, raw.verbose)
  if extracted.isErr:
    return LxResult[void].err(extracted.error())

  let manifestPath = packageDir / manifestFileName
  let originalManifest = readManifest(manifestPath)
  if originalManifest.isErr:
    return LxResult[void].err(originalManifest.error())

  let imagePath = verifyImageFile(originalManifest.get(), packageDir)
  if imagePath.isErr:
    return LxResult[void].err(imagePath.error())

  let optsResult = resolveRewriteMetadataOptions(raw, originalManifest.get())
  if optsResult.isErr:
    return LxResult[void].err(optsResult.error())

  let opts = optsResult.get()
  printRewriteMetadataOptions(opts, originalManifest.get())

  let rewritten = rewriteManifest(originalManifest.get(), opts)
  let written = writeManifest(rewritten, manifestPath)
  if written.isErr:
    return LxResult[void].err(written.error())

  let archiveResult = createArchiveWithImageName(
    manifestPath,
    imagePath.get(),
    originalManifest.get().image.file,
    opts.outputFile,
    opts.force,
    opts.verbose
  )
  if archiveResult.isErr:
    return LxResult[void].err(archiveResult.error())

  echo &"Created package: {opts.outputFile}"
  result = LxResult[void].ok()

proc rewriteMetadataPackage(raw: RawRewriteMetadataOptions): LxResult[void] =
  let buildDirResult = createRewriteMetadataDir()
  if buildDirResult.isErr:
    return LxResult[void].err(buildDirResult.error())

  let buildDir = buildDirResult.get()
  let rewriteResult = rewriteMetadataSteps(raw, buildDir)

  if rewriteResult.isOk:
    if raw.keepWorkdir:
      echo &"Temporary rewrite-metadata directory kept: {buildDir}"
      return rewriteResult

    let cleanup = removeRewriteMetadataDir(buildDir)
    if cleanup.isErr:
      return cleanup

    return rewriteResult

  warnKeptRewriteMetadataDir(buildDir)
  result = rewriteResult

proc runRewriteMetadata*(opts: RawRewriteMetadataOptions): LxResult[void] =
  result = rewriteMetadataPackage(opts)
