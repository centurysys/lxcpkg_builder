# Build .lxcpkg packages from LXC download-template output.
#
# build-download intentionally delegates image index handling to the standard
# LXC download template. lxcpkg focuses on converting the downloaded rootfs into
# the product-oriented squashfs based package format.

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
  DownloadArchitecture = object
    lxcArch: string
    manifestArch: string

  RawPackLxcDirOptions* = object
    lxcDir*: Option[string]
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
    force*: bool
    verbose*: bool
    keepWorkdir*: bool

  RawBuildDownloadOptions* = object
    dist*: Option[string]
    release*: Option[string]
    arch*: Option[string]
    bits*: Option[string]
    output*: Option[string]
    packageId*: Option[string]
    name*: Option[string]
    version*: Option[string]
    rootfsMode*: Option[string]
    compression*: Option[string]
    blockSize*: Option[string]
    data*: seq[string]
    exclude*: seq[string]
    normalize*: Option[string]
    minimize*: Option[string]
    networkMode*: Option[string]
    interactive*: bool
    workDir*: Option[string]
    keepWorkdir*: bool
    force*: bool
    verbose*: bool

proc optionValue(value: Option[string]; defaultValue: string): string =
  if value.isSome and value.get().len > 0:
    result = value.get()
  else:
    result = defaultValue

proc parseDownloadArchitecture(archOpt, bitsOpt: Option[string]): LxResult[DownloadArchitecture] =
  if archOpt.isSome and bitsOpt.isSome:
    return LxResult[DownloadArchitecture].err(
      invalidArgument("--arch and --bits cannot be used together")
    )

  let text =
    if archOpt.isSome:
      archOpt.get().strip().toLowerAscii()
    elif bitsOpt.isSome:
      bitsOpt.get().strip().toLowerAscii()
    else:
      "64"

  case text
  of "64", "arm64", "aarch64":
    result = LxResult[DownloadArchitecture].ok(DownloadArchitecture(lxcArch: "arm64", manifestArch: "aarch64"))
  of "32", "armhf", "armv7", "armv7l":
    result = LxResult[DownloadArchitecture].ok(DownloadArchitecture(lxcArch: "armhf", manifestArch: "armhf"))
  else:
    result = LxResult[DownloadArchitecture].err(
      unsupportedArch("unsupported architecture", "supported architectures are arm64/aarch64 and armhf")
    )

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

proc runCommand(command: string; args: seq[string]; verbose, parentStreams: bool): LxResult[void] =
  if verbose:
    let argText = args.join(" ")
    echo &"{command} {argText}"

  let options =
    if parentStreams:
      {poUsePath, poParentStreams}
    else:
      {poUsePath, poStdErrToStdOut}

  let process =
    try:
      startProcess(command, args = args, options = options)
    except OSError as e:
      return LxResult[void].err(ioError("failed to start external command", e.msg))

  var output = ""
  if not parentStreams:
    let outputResult = readProcessOutput(process)
    if outputResult.isErr:
      process.close()
      return LxResult[void].err(outputResult.error())
    output = outputResult.get()

  let code =
    try:
      process.waitForExit()
    finally:
      process.close()

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
    let path = parent / &"lxcpkg-build-download-{pid}-{stamp}-{index}"
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

proc parseLxcConfigValue(line, key: string): Option[string] =
  let stripped = line.strip()
  if stripped.len == 0 or stripped.startsWith("#"):
    return none(string)

  let pos = stripped.find('=')
  if pos < 0:
    return none(string)

  let lhs = stripped[0 ..< pos].strip()
  if lhs != key:
    return none(string)

  result = some(stripped[pos + 1 .. ^1].strip())

proc readLxcConfigValue(configFile, key: string): LxResult[string] =
  try:
    for line in lines(configFile):
      let value = parseLxcConfigValue(line, key)
      if value.isSome:
        return LxResult[string].ok(value.get())
  except IOError as e:
    return LxResult[string].err(ioError("failed to read LXC config", e.msg))
  except OSError as e:
    return LxResult[string].err(ioError("failed to read LXC config", e.msg))

  result = LxResult[string].err(invalidArgument(&"missing LXC config key: {key}", configFile))

proc resolveLxcRootfsPath(lxcDir: string): LxResult[string] =
  let configFile = lxcDir / "config"
  if not fileExists(configFile):
    return LxResult[string].err(invalidArgument("LXC config does not exist", configFile))

  let rawPath = readLxcConfigValue(configFile, "lxc.rootfs.path")
  if rawPath.isErr:
    return LxResult[string].err(rawPath.error())

  var path = rawPath.get()
  if path.startsWith("dir:"):
    path = path[4 .. ^1]

  if not path.isAbsolute():
    path = absolutePath(lxcDir / path)

  if not dirExists(path):
    return LxResult[string].err(invalidRootfs("LXC rootfs directory does not exist", path))

  result = LxResult[string].ok(path)

proc packageNameFromLxcDir(lxcDir: string; explicitName: Option[string]): Option[string] =
  if explicitName.isSome and explicitName.get().len > 0:
    return explicitName

  let fallback = lxcDir.extractFilename()
  if fallback.len > 0:
    return some(fallback)

  result = none(string)

proc resolveProfiles(
    normalizeOpt, minimizeOpt, networkModeOpt: Option[string]
): LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)] =
  let normalize = parseNormalizeProfile(optionValue(normalizeOpt, "none"))
  if normalize.isErr:
    return LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].err(normalize.error())

  let minimize = parseMinimizeProfile(optionValue(minimizeOpt, "none"))
  if minimize.isErr:
    return LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].err(minimize.error())

  let networkMode = parseNetworkMode(optionValue(networkModeOpt, "dhcp"))
  if networkMode.isErr:
    return LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].err(networkMode.error())

  result = LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].ok((normalize.get(), minimize.get(), networkMode.get()))

proc runPackLxcDir*(opts: RawPackLxcDirOptions): LxResult[void] =
  if opts.lxcDir.isNone or opts.lxcDir.get().len == 0:
    return LxResult[void].err(missingArgument("--lxc-dir"))

  let lxcDir = absolutePath(opts.lxcDir.get())
  let rootfsPath = resolveLxcRootfsPath(lxcDir)
  if rootfsPath.isErr:
    return LxResult[void].err(rootfsPath.error())

  let profiles = resolveProfiles(opts.normalize, opts.minimize, opts.networkMode)
  if profiles.isErr:
    return LxResult[void].err(profiles.error())

  let (normalize, minimize, networkMode) = profiles.get()
  let tuned = applyRootfsProfiles(rootfsPath.get(), normalize, minimize, networkMode, opts.verbose)
  if tuned.isErr:
    return LxResult[void].err(tuned.error())

  let rawBuild = RawBuildOptions(
    rootfs: some(rootfsPath.get()),
    output: opts.output,
    packageId: opts.packageId,
    name: packageNameFromLxcDir(lxcDir, opts.name),
    version: opts.version,
    arch: opts.arch,
    rootfsMode: opts.rootfsMode,
    compression: opts.compression,
    blockSize: opts.blockSize,
    data: opts.data,
    exclude: opts.exclude,
    nonInteractive: true,
    force: opts.force,
    verbose: opts.verbose,
    keepWorkdir: opts.keepWorkdir
  )

  result = runBuild(rawBuild)

proc downloadedLxcDir(workDir, name: string): string =
  result = workDir / "lxc" / name

proc runLxcDownload(opts: RawBuildDownloadOptions; workDir, tmpName, lxcArch: string): LxResult[void] =
  try:
    createDir(workDir / "lxc")
  except OSError as e:
    return LxResult[void].err(ioError("failed to create LXC work directory", e.msg))

  let lxcCreate = findRequiredTool("lxc-create")
  if lxcCreate.isErr:
    return LxResult[void].err(lxcCreate.error())

  var args = @["-t", "download", "-P", workDir / "lxc", "-n", tmpName]

  if opts.interactive:
    args.add("--")
    if lxcArch.len > 0:
      args.add("-a")
      args.add(lxcArch)
  else:
    if opts.dist.isNone or opts.dist.get().len == 0:
      return LxResult[void].err(missingArgument("--dist"))
    if opts.release.isNone or opts.release.get().len == 0:
      return LxResult[void].err(missingArgument("--release"))

    args.add("--")
    args.add("-a")
    args.add(lxcArch)
    args.add("-d")
    args.add(opts.dist.get())
    args.add("-r")
    args.add(opts.release.get())

  result = runCommand(lxcCreate.get(), args, opts.verbose, opts.interactive)

proc runBuildDownload*(opts: RawBuildDownloadOptions): LxResult[void] =
  let arch = parseDownloadArchitecture(opts.arch, opts.bits)
  if arch.isErr:
    return LxResult[void].err(arch.error())

  let name =
    if opts.name.isSome and opts.name.get().len > 0:
      opts.name.get()
    elif opts.dist.isSome and opts.release.isSome:
      &"{opts.dist.get()}{opts.release.get()}"
    else:
      "downloaded"

  let workDir = makeWorkDir(optionValue(opts.workDir, ""))
  if workDir.isErr:
    return LxResult[void].err(workDir.error())

  let tmpName = &"{name}-work"
  let downloadResult = runLxcDownload(opts, workDir.get(), tmpName, arch.get().lxcArch)
  if downloadResult.isErr:
    if opts.keepWorkdir:
      stderr.writeLine(&"Work directory was kept for inspection: {workDir.get()}")
    else:
      discard removeWorkDir(workDir.get())
    return LxResult[void].err(downloadResult.error())

  let lxcDir = downloadedLxcDir(workDir.get(), tmpName)
  let packOpts = RawPackLxcDirOptions(
    lxcDir: some(lxcDir),
    output: opts.output,
    packageId: opts.packageId,
    name: some(name),
    version: opts.version,
    arch: some(arch.get().manifestArch),
    rootfsMode: opts.rootfsMode,
    compression: opts.compression,
    blockSize: opts.blockSize,
    data: opts.data,
    exclude: opts.exclude,
    normalize: opts.normalize,
    minimize: opts.minimize,
    networkMode: opts.networkMode,
    force: opts.force,
    verbose: opts.verbose,
    keepWorkdir: opts.keepWorkdir
  )

  let packResult = runPackLxcDir(packOpts)
  if packResult.isOk:
    if opts.keepWorkdir:
      echo &"Work directory kept: {workDir.get()}"
      return packResult

    let removed = removeWorkDir(workDir.get())
    if removed.isErr:
      return removed

    return packResult

  if opts.keepWorkdir:
    stderr.writeLine(&"Work directory was kept for inspection: {workDir.get()}")
  else:
    discard removeWorkDir(workDir.get())

  result = packResult
