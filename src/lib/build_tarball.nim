# Build .lxcpkg packages from rootfs tarballs.
#
# This command is useful when a rootfs archive has already been downloaded by
# CI, a mirror, or a manual workflow. It extracts the tarball into a temporary
# work directory, applies the same rootfs tuning profiles used by build-download,
# and then reuses the normal build path.

import std/options
import std/os
import std/osproc
import std/streams
import std/strformat
import std/strutils
import std/times
import results

import build
import errors
import rootfs_tune

type
  RawBuildTarballOptions* = object
    tarball*: Option[string]
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
    workDir*: Option[string]
    keepWorkdir*: bool
    force*: bool
    verbose*: bool

proc optionValue(value: Option[string]; defaultValue: string): string =
  if value.isSome and value.get().len > 0:
    result = value.get()
  else:
    result = defaultValue

proc findRequiredTool(tool: string): LxResult[string] =
  let path = findExe(tool)
  if path.len == 0:
    return LxResult[string].err(externalToolMissing(tool))

  result = LxResult[string].ok(path)

proc readProcessOutput(process: Process): LxResult[string] =
  try:
    result = LxResult[string].ok(process.outputStream.readAll())
  except IOError as e:
    result = LxResult[string].err(ioError("failed to read external command output", e.msg))

proc runCommand(command: string; args: seq[string]; workingDir: string; verbose: bool): LxResult[void] =
  if verbose:
    let argText = args.join(" ")
    echo &"{command} {argText}"

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
    return LxResult[void].err(externalCommandFailed(command, code, output.strip()))

  if verbose and output.len > 0:
    stdout.write(output)

  result = LxResult[void].ok()

proc makeWorkDir(base: string): LxResult[string] =
  let parent =
    if base.len > 0:
      base
    else:
      "/var/tmp"

  if not dirExists(parent):
    return LxResult[string].err(ioError("work directory parent does not exist", parent))

  let pid = getCurrentProcessId()
  let stamp = int(epochTime())
  for index in 0 ..< 1000:
    let path = parent / &"lxcpkg-build-tarball-{pid}-{stamp}-{index}"
    if dirExists(path) or fileExists(path):
      continue

    try:
      createDir(path)
      return LxResult[string].ok(path)
    except OSError as e:
      return LxResult[string].err(ioError("failed to create work directory", e.msg))

  result = LxResult[string].err(ioError("failed to create work directory", parent))

proc removeWorkDir(path: string): LxResult[void] =
  if path.len == 0:
    return LxResult[void].ok()

  try:
    removeDir(path)
    result = LxResult[void].ok()
  except OSError as e:
    result = LxResult[void].err(ioError("failed to remove work directory", e.msg))

proc stripKnownTarballExtension(path: string): string =
  let name = path.extractFilename()
  let lower = name.toLowerAscii()
  let extensions = [
    ".tar.zst",
    ".tar.zstd",
    ".tar.xz",
    ".tar.gz",
    ".tar.bz2",
    ".tgz",
    ".txz",
    ".tbz2",
    ".tar"
  ]

  for ext in extensions:
    if lower.endsWith(ext):
      return name[0 ..< name.len - ext.len]

  result = name

proc defaultNameFromTarball(tarball: string; explicitName: Option[string]): Option[string] =
  if explicitName.isSome and explicitName.get().len > 0:
    return explicitName

  let fallback = stripKnownTarballExtension(tarball)
  if fallback.len > 0:
    return some(fallback)

  result = none(string)

proc resolveProfiles(
    presetOpt, normalizeOpt, minimizeOpt, networkModeOpt: Option[string]
): LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)] =
  result = resolveRootfsProfileSelection(
    optionValue(presetOpt, "none"),
    optionValue(normalizeOpt, "none"),
    optionValue(minimizeOpt, "none"),
    optionValue(networkModeOpt, "dhcp")
  )

proc extractTarball(tarball, extractDir: string; verbose: bool): LxResult[void] =
  let tar = findRequiredTool("tar")
  if tar.isErr:
    return LxResult[void].err(tar.error())

  try:
    createDir(extractDir)
  except OSError as e:
    return LxResult[void].err(ioError("failed to create tarball extraction directory", e.msg))

  let args = @["-xf", absolutePath(tarball), "-C", extractDir]
  result = runCommand(tar.get(), args, getCurrentDir(), verbose)

proc rootfsLooksUsable(path: string): bool =
  if not dirExists(path):
    return false

  result =
    fileExists(path / "etc" / "passwd") and
    fileExists(path / "etc" / "group")

proc findExtractedRootfs(extractDir: string): LxResult[string] =
  if rootfsLooksUsable(extractDir):
    return LxResult[string].ok(extractDir)

  var candidates: seq[string] = @[]
  try:
    for kind, path in walkDir(extractDir):
      if kind == pcDir and rootfsLooksUsable(path):
        candidates.add(path)
  except OSError as e:
    return LxResult[string].err(ioError("failed to inspect extracted tarball", e.msg))

  if candidates.len == 1:
    return LxResult[string].ok(candidates[0])

  if candidates.len == 0:
    return LxResult[string].err(
      invalidRootfs(
        "could not find rootfs in extracted tarball",
        "expected etc/passwd and etc/group at archive root or in a single top-level directory"
      )
    )

  result = LxResult[string].err(
    invalidRootfs(
      "multiple rootfs candidates were found in extracted tarball",
      candidates.join(", ")
    )
  )

proc runBuildTarball*(opts: RawBuildTarballOptions): LxResult[void] =
  if opts.tarball.isNone or opts.tarball.get().len == 0:
    return LxResult[void].err(missingArgument("--tarball"))

  let tarball = absolutePath(opts.tarball.get())
  if not fileExists(tarball):
    return LxResult[void].err(ioError("tarball does not exist", tarball))

  let profiles = resolveProfiles(opts.preset, opts.normalize, opts.minimize, opts.networkMode)
  if profiles.isErr:
    return LxResult[void].err(profiles.error())

  let workDir = makeWorkDir(optionValue(opts.workDir, ""))
  if workDir.isErr:
    return LxResult[void].err(workDir.error())

  let extractDir = workDir.get() / "rootfs-extract"
  let extractResult = extractTarball(tarball, extractDir, opts.verbose)
  if extractResult.isErr:
    if opts.keepWorkdir:
      stderr.writeLine(&"Work directory was kept for inspection: {workDir.get()}")
    else:
      discard removeWorkDir(workDir.get())
    return LxResult[void].err(extractResult.error())

  let rootfsPath = findExtractedRootfs(extractDir)
  if rootfsPath.isErr:
    if opts.keepWorkdir:
      stderr.writeLine(&"Work directory was kept for inspection: {workDir.get()}")
    else:
      discard removeWorkDir(workDir.get())
    return LxResult[void].err(rootfsPath.error())

  let (normalize, minimize, networkMode) = profiles.get()
  let tuned = applyRootfsProfiles(rootfsPath.get(), normalize, minimize, networkMode, opts.verbose)
  if tuned.isErr:
    if opts.keepWorkdir:
      stderr.writeLine(&"Work directory was kept for inspection: {workDir.get()}")
    else:
      discard removeWorkDir(workDir.get())
    return LxResult[void].err(tuned.error())

  let rawBuild = RawBuildOptions(
    rootfs: some(rootfsPath.get()),
    output: opts.output,
    packageId: opts.packageId,
    name: defaultNameFromTarball(tarball, opts.name),
    version: opts.version,
    arch: opts.arch,
    rootfsMode: opts.rootfsMode,
    compression: opts.compression,
    blockSize: opts.blockSize,
    data: opts.data,
    exclude: opts.exclude,
    normalize: none(string),
    minimize: none(string),
    networkMode: none(string),
    preset: none(string),
    nonInteractive: true,
    force: opts.force,
    verbose: opts.verbose,
    keepWorkdir: opts.keepWorkdir
  )

  let buildResult = runBuild(rawBuild)
  if buildResult.isOk:
    if opts.keepWorkdir:
      echo &"Work directory kept: {workDir.get()}"
      return buildResult

    let removed = removeWorkDir(workDir.get())
    if removed.isErr:
      return removed

    return buildResult

  if opts.keepWorkdir:
    stderr.writeLine(&"Work directory was kept for inspection: {workDir.get()}")
  else:
    discard removeWorkDir(workDir.get())

  result = buildResult
