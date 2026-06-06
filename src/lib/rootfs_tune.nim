# Product-oriented rootfs normalization and minimization helpers.
#
# These helpers are intentionally conservative. Any destructive operation is
# executed inside a bubblewrap sandbox: the host root filesystem is mounted
# read-only, and only the target rootfs is mounted read-write at /mnt. This
# prevents cleanup rules from deleting files on the host even when rootfs paths
# contain unexpected symlinks or bad input.

import std/os
import std/osproc
import std/streams
import std/strformat
import std/strutils
import results

import errors

type
  NormalizeProfile* = enum
    npNone = "none"
    npProduct = "product"

  MinimizeProfile* = enum
    mpNone = "none"
    mpAuto = "auto"
    mpAlpine = "alpine"
    mpDebian = "debian"

  NetworkMode* = enum
    nmDhcp = "dhcp"
    nmHostConfigured = "host-configured"

  AppliancePreset* = enum
    apNone = "none"
    apAuto = "auto-appliance"
    apAlpine = "alpine-appliance"
    apDebian = "debian-appliance"
    apUbuntu = "ubuntu-appliance"

  OsRelease* = object
    id*: string
    idLike*: seq[string]
    versionId*: string

const
  sandboxRoot = "/mnt"

proc parseNormalizeProfile*(text: string): LxResult[NormalizeProfile] =
  case text.strip().toLowerAscii()
  of "", "none":
    result = LxResult[NormalizeProfile].ok(npNone)
  of "product":
    result = LxResult[NormalizeProfile].ok(npProduct)
  else:
    result = LxResult[NormalizeProfile].err(
      invalidArgument("invalid normalize profile", "allowed values: none, product")
    )

proc parseMinimizeProfile*(text: string): LxResult[MinimizeProfile] =
  case text.strip().toLowerAscii()
  of "", "none":
    result = LxResult[MinimizeProfile].ok(mpNone)
  of "auto":
    result = LxResult[MinimizeProfile].ok(mpAuto)
  of "alpine":
    result = LxResult[MinimizeProfile].ok(mpAlpine)
  of "debian":
    result = LxResult[MinimizeProfile].ok(mpDebian)
  else:
    result = LxResult[MinimizeProfile].err(
      invalidArgument("invalid minimize profile", "allowed values: none, auto, alpine, debian")
    )

proc parseNetworkMode*(text: string): LxResult[NetworkMode] =
  case text.strip().toLowerAscii()
  of "", "dhcp":
    result = LxResult[NetworkMode].ok(nmDhcp)
  of "host-configured":
    result = LxResult[NetworkMode].ok(nmHostConfigured)
  else:
    result = LxResult[NetworkMode].err(
      invalidArgument("invalid network mode", "allowed values: dhcp, host-configured")
    )

proc parseAppliancePreset*(text: string): LxResult[AppliancePreset] =
  case text.strip().toLowerAscii()
  of "", "none":
    result = LxResult[AppliancePreset].ok(apNone)
  of "auto-appliance":
    result = LxResult[AppliancePreset].ok(apAuto)
  of "alpine-appliance":
    result = LxResult[AppliancePreset].ok(apAlpine)
  of "debian-appliance":
    result = LxResult[AppliancePreset].ok(apDebian)
  of "ubuntu-appliance":
    result = LxResult[AppliancePreset].ok(apUbuntu)
  else:
    result = LxResult[AppliancePreset].err(
      invalidArgument(
        "invalid preset",
        "allowed values: none, auto-appliance, alpine-appliance, debian-appliance, ubuntu-appliance"
      )
    )

proc resolveRootfsProfileSelection*(
    presetText, normalizeText, minimizeText, networkModeText: string
): LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)] =
  let preset = parseAppliancePreset(presetText)
  if preset.isErr:
    return LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].err(preset.error())

  case preset.get()
  of apNone:
    let normalize = parseNormalizeProfile(normalizeText)
    if normalize.isErr:
      return LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].err(normalize.error())

    let minimize = parseMinimizeProfile(minimizeText)
    if minimize.isErr:
      return LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].err(minimize.error())

    let networkMode = parseNetworkMode(networkModeText)
    if networkMode.isErr:
      return LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].err(networkMode.error())

    result = LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].ok(
      (normalize.get(), minimize.get(), networkMode.get())
    )
  of apAuto:
    result = LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].ok(
      (npProduct, mpAuto, nmHostConfigured)
    )
  of apAlpine:
    result = LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].ok(
      (npProduct, mpAlpine, nmHostConfigured)
    )
  of apDebian, apUbuntu:
    result = LxResult[(NormalizeProfile, MinimizeProfile, NetworkMode)].ok(
      (npProduct, mpDebian, nmHostConfigured)
    )

proc normalizeRelativePath(relativePath: string): LxResult[string] =
  if relativePath.len == 0 or relativePath.startsWith("/"):
    return LxResult[string].err(invalidArgument("unsafe rootfs path", relativePath))

  let slashPath = relativePath.replace('\\', '/')
  for part in slashPath.split('/'):
    if part == "..":
      return LxResult[string].err(invalidArgument("unsafe rootfs path", relativePath))

  let normalized = slashPath.normalizedPath()
  if normalized.len == 0 or normalized == ".":
    return LxResult[string].err(invalidArgument("unsafe rootfs path", relativePath))

  result = LxResult[string].ok(normalized)

proc checkedPath(rootfs, relativePath: string): LxResult[string] =
  let rel = normalizeRelativePath(relativePath)
  if rel.isErr:
    return LxResult[string].err(rel.error())

  if rootfs.len == 0 or rootfs == "/":
    return LxResult[string].err(invalidRootfs("refusing to use unsafe rootfs", rootfs))

  let rootAbs = absolutePath(rootfs).normalizedPath()
  if rootAbs == "/":
    return LxResult[string].err(invalidRootfs("refusing to use host rootfs", rootfs))

  let path = absolutePath(rootAbs / rel.get()).normalizedPath()
  if path != rootAbs and not path.startsWith(rootAbs / ""):
    return LxResult[string].err(invalidArgument("rootfs path escapes root", relativePath))

  result = LxResult[string].ok(path)

proc sandboxPath(relativePath: string): LxResult[string] =
  let rel = normalizeRelativePath(relativePath)
  if rel.isErr:
    return LxResult[string].err(rel.error())

  result = LxResult[string].ok(sandboxRoot / rel.get())

proc validateSandboxRootfs(rootfs: string): LxResult[string] =
  if rootfs.len == 0:
    return LxResult[string].err(invalidRootfs("rootfs path is empty"))

  let rootAbs = absolutePath(rootfs).normalizedPath()
  if rootAbs == "/":
    return LxResult[string].err(invalidRootfs("refusing to modify host rootfs", rootfs))
  if symlinkExists(rootAbs):
    return LxResult[string].err(invalidRootfs("refusing to modify symlink rootfs", rootfs))
  if not dirExists(rootAbs):
    return LxResult[string].err(invalidRootfs("rootfs directory does not exist", rootfs))

  result = LxResult[string].ok(rootAbs)

proc readProcessOutput(process: Process): LxResult[string] =
  try:
    result = LxResult[string].ok(process.outputStream.readAll())
  except IOError as e:
    result = LxResult[string].err(ioError("failed to read external command output", e.msg))

proc runCommand(command: string; args: seq[string]; verbose: bool): LxResult[void] =
  if verbose:
    let argText = args.join(" ")
    echo &"{command} {argText}"

  let process =
    try:
      startProcess(command, args = args, options = {poUsePath, poStdErrToStdOut})
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

proc runSandboxCommand(rootfs, command: string; args: seq[string]; verbose: bool): LxResult[void] =
  let rootAbs = validateSandboxRootfs(rootfs)
  if rootAbs.isErr:
    return LxResult[void].err(rootAbs.error())

  let bwrap = findExe("bwrap")
  if bwrap.len == 0:
    return LxResult[void].err(externalToolMissing("bwrap"))

  # The destination /mnt already exists in normal host roots, so the target
  # rootfs can be mounted there without creating writable directories outside
  # the sandbox. The original host / is visible read-only; only /mnt is rw.
  var bwrapArgs = @[
    "--die-with-parent",
    "--unshare-all",
    "--ro-bind", "/", "/",
    "--bind", rootAbs.get(), sandboxRoot,
    command
  ]
  bwrapArgs.add(args)

  result = runCommand(bwrap, bwrapArgs, verbose)

proc clearDirContents(rootfs, relativePath: string; verbose: bool): LxResult[void] =
  let target = sandboxPath(relativePath)
  if target.isErr:
    return LxResult[void].err(target.error())

  let find = findExe("find")
  if find.len == 0:
    return LxResult[void].err(externalToolMissing("find"))

  let script = "target=$1; find_cmd=$2; if [ -d \"$target\" ]; then exec \"$find_cmd\" \"$target\" -xdev -mindepth 1 -delete; fi"
  result = runSandboxCommand(rootfs, "/bin/sh", @["-eu", "-c", script, "sh", target.get(), find], verbose)

proc removePathIfExists(rootfs, relativePath: string; verbose = false): LxResult[void] =
  let target = sandboxPath(relativePath)
  if target.isErr:
    return LxResult[void].err(target.error())

  let script = "target=$1; if [ -L \"$target\" ] || [ -f \"$target\" ]; then rm -f \"$target\"; elif [ -d \"$target\" ]; then rmdir \"$target\"; fi"
  result = runSandboxCommand(rootfs, "/bin/sh", @["-eu", "-c", script, "sh", target.get()], verbose)

proc writeRootfsFile(rootfs, relativePath, content: string; verbose = false): LxResult[void] =
  let target = sandboxPath(relativePath)
  if target.isErr:
    return LxResult[void].err(target.error())

  let script = "target=$1; content=$2; parent=${target%/*}; mkdir -p \"$parent\"; if [ -L \"$target\" ]; then rm -f \"$target\"; fi; printf '%s' \"$content\" > \"$target\""
  result = runSandboxCommand(rootfs, "/bin/sh", @["-eu", "-c", script, "sh", target.get(), content], verbose)

proc unquoteOsReleaseValue(value: string): string =
  result = value.strip()
  if result.len >= 2:
    if (result[0] == '"' and result[^1] == '"') or (result[0] == '\'' and result[^1] == '\''):
      result = result[1 .. ^2]

proc readOsRelease*(rootfs: string): LxResult[OsRelease] =
  let pathResult = checkedPath(rootfs, "etc/os-release")
  if pathResult.isErr:
    return LxResult[OsRelease].err(pathResult.error())

  let path = pathResult.get()
  if not fileExists(path):
    return LxResult[OsRelease].ok(OsRelease(id: "", idLike: @[], versionId: ""))

  var osrel = OsRelease(id: "", idLike: @[], versionId: "")
  try:
    for line in lines(path):
      let stripped = line.strip()
      if stripped.len == 0 or stripped.startsWith("#"):
        continue

      let pos = stripped.find('=')
      if pos < 0:
        continue

      let key = stripped[0 ..< pos]
      let value = unquoteOsReleaseValue(stripped[pos + 1 .. ^1])
      case key
      of "ID":
        osrel.id = value.toLowerAscii()
      of "ID_LIKE":
        osrel.idLike = value.toLowerAscii().splitWhitespace()
      of "VERSION_ID":
        osrel.versionId = value
      else:
        discard
  except IOError as e:
    return LxResult[OsRelease].err(ioError("failed to read /etc/os-release", e.msg))
  except OSError as e:
    return LxResult[OsRelease].err(ioError("failed to read /etc/os-release", e.msg))

  result = LxResult[OsRelease].ok(osrel)

proc isAlpine(osrel: OsRelease): bool =
  result = osrel.id == "alpine" or osrel.idLike.contains("alpine")

proc isDebianLike(osrel: OsRelease): bool =
  result = osrel.id == "debian" or osrel.id == "ubuntu" or osrel.id == "devuan" or
    osrel.idLike.contains("debian") or osrel.idLike.contains("ubuntu")

proc normalizeProduct*(rootfs: string; verbose = false): LxResult[void] =
  let sandboxReady = validateSandboxRootfs(rootfs)
  if sandboxReady.isErr:
    return LxResult[void].err(sandboxReady.error())

  let resolv = checkedPath(rootfs, "etc/resolv.conf")
  if resolv.isErr:
    return LxResult[void].err(resolv.error())

  try:
    if symlinkExists(resolv.get()):
      if verbose:
        echo "Replacing symlink /etc/resolv.conf with a regular file inside bubblewrap sandbox"
      let written = writeRootfsFile(rootfs, "etc/resolv.conf", "# Managed by host LXC configuration\n", verbose)
      if written.isErr:
        return written
  except OSError as e:
    return LxResult[void].err(ioError("failed to normalize /etc/resolv.conf", e.msg))

  let scrubMachineId = writeRootfsFile(rootfs, "etc/machine-id", "", verbose)
  if scrubMachineId.isErr:
    return scrubMachineId

  let dbusMachineIdRemoved = removePathIfExists(rootfs, "var/lib/dbus/machine-id", verbose)
  if dbusMachineIdRemoved.isErr:
    return dbusMachineIdRemoved

  for dir in ["tmp", "var/tmp", "var/log"]:
    let cleaned = clearDirContents(rootfs, dir, verbose)
    if cleaned.isErr:
      return cleaned

  result = LxResult[void].ok()

proc minimizeAlpine*(rootfs: string; verbose = false): LxResult[void] =
  for dir in ["var/cache/apk", "tmp", "var/tmp", "var/log"]:
    let cleaned = clearDirContents(rootfs, dir, verbose)
    if cleaned.isErr:
      return cleaned

  result = LxResult[void].ok()

proc minimizeDebian*(rootfs: string; verbose = false): LxResult[void] =
  let aptConf = """
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
""".strip() & "\n"

  let dpkgConf = """
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/linda/*
path-exclude=/usr/share/locale/*
""".strip() & "\n"

  let aptWritten = writeRootfsFile(rootfs, "etc/apt/apt.conf.d/99-lxcpkg-minimize", aptConf, verbose)
  if aptWritten.isErr:
    return aptWritten

  let dpkgWritten = writeRootfsFile(rootfs, "etc/dpkg/dpkg.cfg.d/99-lxcpkg-minimize", dpkgConf, verbose)
  if dpkgWritten.isErr:
    return dpkgWritten

  for dir in ["var/cache/apt/archives", "var/cache/apt", "var/lib/apt/lists", "tmp", "var/tmp", "var/log"]:
    let cleaned = clearDirContents(rootfs, dir, verbose)
    if cleaned.isErr:
      return cleaned

  result = LxResult[void].ok()

proc applyMinimizeProfile*(rootfs: string; profile: MinimizeProfile; verbose = false): LxResult[void] =
  var actual = profile
  if actual == mpAuto:
    let osrel = readOsRelease(rootfs)
    if osrel.isErr:
      return LxResult[void].err(osrel.error())

    if isAlpine(osrel.get()):
      actual = mpAlpine
    elif isDebianLike(osrel.get()):
      actual = mpDebian
    else:
      actual = mpNone

  case actual
  of mpNone, mpAuto:
    result = LxResult[void].ok()
  of mpAlpine:
    result = minimizeAlpine(rootfs, verbose)
  of mpDebian:
    result = minimizeDebian(rootfs, verbose)

proc applyHostConfiguredNetwork*(rootfs: string; verbose = false): LxResult[void] =
  let osrel = readOsRelease(rootfs)
  if osrel.isErr:
    return LxResult[void].err(osrel.error())

  if isAlpine(osrel.get()):
    if verbose:
      echo "Disabling Alpine default networking service inside bubblewrap sandbox"
    return removePathIfExists(rootfs, "etc/runlevels/default/networking", verbose)

  # Other distributions are intentionally left unchanged for now. Fedora and
  # full systemd distros have several possible network managers, and blindly
  # disabling services here is more dangerous than useful.
  result = LxResult[void].ok()

proc applyRootfsProfiles*(
    rootfs: string,
    normalize: NormalizeProfile,
    minimize: MinimizeProfile,
    networkMode: NetworkMode,
    verbose = false
): LxResult[void] =
  if normalize != npNone or minimize != mpNone or networkMode == nmHostConfigured:
    let sandboxReady = validateSandboxRootfs(rootfs)
    if sandboxReady.isErr:
      return LxResult[void].err(sandboxReady.error())

  if normalize == npProduct:
    let normalized = normalizeProduct(rootfs, verbose)
    if normalized.isErr:
      return normalized

  let minimized = applyMinimizeProfile(rootfs, minimize, verbose)
  if minimized.isErr:
    return minimized

  if networkMode == nmHostConfigured:
    let networkAdjusted = applyHostConfiguredNetwork(rootfs, verbose)
    if networkAdjusted.isErr:
      return networkAdjusted

  result = LxResult[void].ok()
