# SSH host key regeneration helpers.
#
# lxcpkg release cleanup removes OpenSSH host keys so redistributed packages do
# not carry machine-specific identity. Debian/Ubuntu systemd ssh.service runs
# `sshd -t` before starting sshd, and that check fails when host keys are
# missing. This module installs a small drop-in that runs `ssh-keygen -A` before
# the original config test, but only when a systemd OpenSSH service is detected.

import std/options
import std/os
import std/strformat
import std/strutils

import results

import errors

type
  SshUnitInfo = object
    name: string
    relativePath: string

const
  ensureDropInName = "10-ensure-host-keys.conf"
  sshdCandidates = [
    "usr/sbin/sshd",
    "usr/local/sbin/sshd",
    "sbin/sshd"
  ]
  sshKeygenCandidates = [
    "usr/bin/ssh-keygen",
    "usr/local/bin/ssh-keygen",
    "bin/ssh-keygen"
  ]
  sshServiceCandidates = [
    SshUnitInfo(name: "ssh.service", relativePath: "etc/systemd/system/ssh.service"),
    SshUnitInfo(name: "ssh.service", relativePath: "lib/systemd/system/ssh.service"),
    SshUnitInfo(name: "ssh.service", relativePath: "usr/lib/systemd/system/ssh.service"),
    SshUnitInfo(name: "sshd.service", relativePath: "etc/systemd/system/sshd.service"),
    SshUnitInfo(name: "sshd.service", relativePath: "lib/systemd/system/sshd.service"),
    SshUnitInfo(name: "sshd.service", relativePath: "usr/lib/systemd/system/sshd.service")
  ]

proc isInsideRoot(root, path: string): bool =
  let rootAbs = absolutePath(root).normalizedPath()
  let pathAbs = absolutePath(path).normalizedPath()

  result = pathAbs == rootAbs or pathAbs.startsWith(rootAbs / "")

proc checkedPath(root, relativePath: string): LxResult[string] =
  if relativePath.len == 0 or relativePath.startsWith("/"):
    return LxResult[string].err(invalidArgument("unsafe rootfs path", relativePath))

  let normalized = relativePath.replace('\\', '/').normalizedPath()
  for part in normalized.split('/'):
    if part == "..":
      return LxResult[string].err(invalidArgument("unsafe rootfs path", relativePath))

  let path = root / normalized
  if not isInsideRoot(root, path):
    return LxResult[string].err(invalidArgument("rootfs path escapes root", relativePath))

  result = LxResult[string].ok(path)


proc unquoteOsReleaseValue(raw: string): string =
  var value = raw.strip()
  if value.len >= 2 and value[0] == '"' and value[^1] == '"':
    value = value[1 .. ^2]

  result = value

proc isDebianLikeRootfs(root: string): LxResult[bool] =
  let osRelease = checkedPath(root, "etc/os-release")
  if osRelease.isErr:
    return LxResult[bool].err(osRelease.error())

  if not fileExists(osRelease.get()):
    return LxResult[bool].ok(false)

  var id = ""
  var idLike: seq[string] = @[]
  try:
    for line in lines(osRelease.get()):
      let stripped = line.strip()
      if stripped.len == 0 or stripped.startsWith("#"):
        continue

      let pos = stripped.find('=')
      if pos < 0:
        continue

      let key = stripped[0 ..< pos]
      let value = unquoteOsReleaseValue(stripped[pos + 1 .. ^1]).toLowerAscii()
      case key
      of "ID":
        id = value
      of "ID_LIKE":
        idLike = value.splitWhitespace()
      else:
        discard
  except IOError as e:
    return LxResult[bool].err(ioError("failed to read /etc/os-release", e.msg))
  except OSError as e:
    return LxResult[bool].err(ioError("failed to read /etc/os-release", e.msg))

  result = LxResult[bool].ok(
    id == "debian" or id == "ubuntu" or
    idLike.contains("debian") or idLike.contains("ubuntu")
  )

proc existingRelativePath(root: string; candidates: openArray[string]): string =
  for relativePath in candidates:
    let checked = checkedPath(root, relativePath)
    if checked.isErr:
      continue
    if fileExists(checked.get()):
      return relativePath

  result = ""

proc existingSshUnit(root: string): Option[SshUnitInfo] =
  for candidate in sshServiceCandidates:
    let checked = checkedPath(root, candidate.relativePath)
    if checked.isErr:
      continue
    if fileExists(checked.get()):
      return some(candidate)

  result = none(SshUnitInfo)

proc dropInDirRelative(unitName: string): string =
  result = "etc/systemd/system" / (unitName & ".d")

proc ensureDropInRelative(unitName: string): string =
  result = dropInDirRelative(unitName) / ensureDropInName

proc readFileSafe(path: string): LxResult[string] =
  try:
    result = LxResult[string].ok(readFile(path))
  except IOError as e:
    result = LxResult[string].err(ioError("failed to read file", e.msg))
  except OSError as e:
    result = LxResult[string].err(ioError("failed to read file", e.msg))

proc dropInAlreadyEnsuresHostKeys(root, unitName: string): LxResult[bool] =
  let dir = checkedPath(root, dropInDirRelative(unitName))
  if dir.isErr:
    return LxResult[bool].err(dir.error())

  if not dirExists(dir.get()):
    return LxResult[bool].ok(false)

  try:
    for kind, path in walkDir(dir.get()):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      if not path.endsWith(".conf"):
        continue

      let content = readFileSafe(path)
      if content.isErr:
        return LxResult[bool].err(content.error())
      if content.get().contains("ssh-keygen -A"):
        return LxResult[bool].ok(true)
  except OSError as e:
    return LxResult[bool].err(ioError("failed to inspect ssh.service drop-ins", e.msg))

  result = LxResult[bool].ok(false)

proc writeEnsureDropIn(root, unitName, sshKeygenRel, sshdRel: string; verbose: bool): LxResult[void] =
  let dropInRel = ensureDropInRelative(unitName)
  let dropIn = checkedPath(root, dropInRel)
  if dropIn.isErr:
    return LxResult[void].err(dropIn.error())

  let dir = dropIn.get().parentDir()
  let content = (&"""
[Service]
ExecStartPre=
ExecStartPre=/{sshKeygenRel} -A
ExecStartPre=/{sshdRel} -t
""").strip() & "\n"

  try:
    createDir(dir)
    if fileExists(dropIn.get()) or symlinkExists(dropIn.get()):
      if verbose:
        echo &"OpenSSH host key drop-in already exists: {dropInRel}"
      return LxResult[void].ok()

    writeFile(dropIn.get(), content)
  except IOError as e:
    return LxResult[void].err(ioError("failed to write ssh host key drop-in", e.msg))
  except OSError as e:
    return LxResult[void].err(ioError("failed to write ssh host key drop-in", e.msg))

  if verbose:
    echo &"Installed OpenSSH host key drop-in: {dropInRel}"

  result = LxResult[void].ok()

proc ensureSshHostKeyDropIn*(rootfsDir: string; verbose = false): LxResult[void] =
  if rootfsDir.len == 0:
    return LxResult[void].err(invalidArgument("rootfs directory must not be empty", ""))

  if not dirExists(rootfsDir):
    return LxResult[void].err(ioError("rootfs directory does not exist", rootfsDir))

  let debianLike = isDebianLikeRootfs(rootfsDir)
  if debianLike.isErr:
    return LxResult[void].err(debianLike.error())
  if not debianLike.get():
    if verbose:
      echo "Debian-like rootfs not detected; skipping SSH host key drop-in"
    return LxResult[void].ok()

  let sshdRel = existingRelativePath(rootfsDir, sshdCandidates)
  if sshdRel.len == 0:
    if verbose:
      echo "OpenSSH server not found; skipping SSH host key drop-in"
    return LxResult[void].ok()

  let sshKeygenRel = existingRelativePath(rootfsDir, sshKeygenCandidates)
  if sshKeygenRel.len == 0:
    if verbose:
      echo "ssh-keygen not found; skipping SSH host key drop-in"
    return LxResult[void].ok()

  let unit = existingSshUnit(rootfsDir)
  if unit.isNone:
    if verbose:
      echo "systemd OpenSSH service not found; skipping SSH host key drop-in"
    return LxResult[void].ok()

  let alreadyEnsures = dropInAlreadyEnsuresHostKeys(rootfsDir, unit.get().name)
  if alreadyEnsures.isErr:
    return LxResult[void].err(alreadyEnsures.error())
  if alreadyEnsures.get():
    if verbose:
      echo &"OpenSSH host key drop-in already configured for {unit.get().name}"
    return LxResult[void].ok()

  result = writeEnsureDropIn(rootfsDir, unit.get().name, sshKeygenRel, sshdRel, verbose)
