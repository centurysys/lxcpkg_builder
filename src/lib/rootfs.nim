# Rootfs inspection helpers.
#
# This module does not modify the rootfs. It only checks that the path looks
# like a root filesystem and detects the supported target architecture from
# ELF binaries inside it.

import std/os
import std/strformat
import std/strutils

when isMainModule:
  import std/parseopt

import results

import errors
import types

const
  elfMagic = [byte 0x7f, byte ord('E'), byte ord('L'), byte ord('F')]
  elfClass32 = byte 1
  elfClass64 = byte 2
  elfDataLsb = byte 1
  elfDataMsb = byte 2
  emArm = uint16 40
  emAarch64 = uint16 183

  archProbeCandidates = [
    "/bin/sh",
    "/usr/bin/env",
    "/usr/bin/bash",
    "/bin/bash",
    "/bin/busybox",
    "/sbin/init",
    "/usr/lib/systemd/systemd"
  ]

proc joinRootfs(rootfs, absolutePath: string): string =
  let rel = absolutePath.strip(chars = {'/'})
  result = rootfs / rel

proc resolveRootfsPath(rootfs, absolutePath: string): LxResult[string] =
  ## Resolve symlinks without escaping the rootfs namespace.
  var current = joinRootfs(rootfs, absolutePath)

  for _ in 0 ..< 16:
    if not symlinkExists(current):
      return LxResult[string].ok(current)

    let linkTarget =
      try:
        expandSymlink(current)
      except OSError as e:
        return LxResult[string].err(ioError("failed to resolve symlink", e.msg))

    if linkTarget.isAbsolute:
      current = joinRootfs(rootfs, linkTarget)
    else:
      current = current.parentDir / linkTarget

  return LxResult[string].err(invalidRootfs("too many symlink levels", absolutePath))

proc readUint16(buf: openArray[byte]; offset: int; lsb: bool): uint16 =
  if lsb:
    result = uint16(buf[offset]) or (uint16(buf[offset + 1]) shl 8)
  else:
    result = (uint16(buf[offset]) shl 8) or uint16(buf[offset + 1])

proc readElfMachine(path: string): LxResult[uint16] =
  var f: File
  if not open(f, path, fmRead):
    return LxResult[uint16].err(ioError("failed to open ELF candidate", path))

  defer:
    f.close()

  var raw: array[20, byte]
  let n =
    try:
      f.readBytes(raw, 0, raw.len)
    except IOError as e:
      return LxResult[uint16].err(ioError("failed to read ELF candidate", e.msg))

  if n < raw.len:
    return LxResult[uint16].err(invalidRootfs("ELF candidate is too small", path))

  for i in 0 ..< elfMagic.len:
    if raw[i] != elfMagic[i]:
      return LxResult[uint16].err(invalidRootfs("file is not an ELF binary", path))

  if raw[4] != elfClass32 and raw[4] != elfClass64:
    return LxResult[uint16].err(invalidRootfs("unsupported ELF class", path))

  let lsb =
    if raw[5] == elfDataLsb:
      true
    elif raw[5] == elfDataMsb:
      false
    else:
      return LxResult[uint16].err(invalidRootfs("unsupported ELF endian", path))

  result = LxResult[uint16].ok(readUint16(raw, 18, lsb))

proc hasArmhfLoader(rootfs: string): bool =
  result =
    fileExists(joinRootfs(rootfs, "/lib/ld-linux-armhf.so.3")) or
    dirExists(joinRootfs(rootfs, "/lib/arm-linux-gnueabihf")) or
    dirExists(joinRootfs(rootfs, "/usr/lib/arm-linux-gnueabihf"))

proc validateRootfsBasic*(rootfs: string): LxResult[void] =
  if rootfs.len == 0:
    return LxResult[void].err(missingArgument("--rootfs"))

  if rootfs == "/":
    return LxResult[void].err(invalidRootfs("refusing to use / as rootfs"))

  if not dirExists(rootfs):
    return LxResult[void].err(invalidRootfs("rootfs directory does not exist", rootfs))

  if not fileExists(rootfs / "etc" / "passwd"):
    return LxResult[void].err(invalidRootfs("rootfs does not contain etc/passwd", rootfs))

  if not fileExists(rootfs / "etc" / "group"):
    return LxResult[void].err(invalidRootfs("rootfs does not contain etc/group", rootfs))

  return LxResult[void].ok()

proc detectRootfsArch*(rootfs: string): LxResult[Architecture] =
  let basic = validateRootfsBasic(rootfs)
  if basic.isErr:
    return LxResult[Architecture].err(basic.error())

  var sawElf = false

  for candidate in archProbeCandidates:
    let resolved = resolveRootfsPath(rootfs, candidate)
    if resolved.isErr:
      continue

    let path = resolved.get()
    if not fileExists(path):
      continue

    let machine = readElfMachine(path)
    if machine.isErr:
      continue

    sawElf = true

    case machine.get()
    of emAarch64:
      return LxResult[Architecture].ok(archAarch64)
    of emArm:
      if hasArmhfLoader(rootfs):
        return LxResult[Architecture].ok(archArmhf)

      return LxResult[Architecture].err(
        unsupportedArch(
          "unsupported ARM rootfs ABI",
          "only armhf is supported for 32-bit ARM rootfs images"
        )
      )
    else:
      return LxResult[Architecture].err(
        unsupportedArch(
          &"unsupported rootfs architecture: e_machine={machine.get()}",
          "only armhf and aarch64 rootfs images are supported"
        )
      )

  if sawElf:
    return LxResult[Architecture].err(
      unsupportedArch("could not find a supported ELF architecture")
    )

  return LxResult[Architecture].err(
    invalidRootfs(
      "could not detect rootfs architecture",
      "check that the rootfs contains ELF binaries such as /bin/sh or /usr/bin/env"
    )
  )

proc resolveArchitecture*(rootfs: string; specified: string): LxResult[Architecture] =
  ## Resolve the final architecture.
  ##
  ## If specified is non-empty, it must be armhf or aarch64 and must match the
  ## detected rootfs architecture.
  let detected = detectRootfsArch(rootfs)
  if detected.isErr:
    return detected

  if specified.len == 0:
    return detected

  let selected =
    case specified
    of "armhf":
      archArmhf
    of "aarch64":
      archAarch64
    else:
      return LxResult[Architecture].err(
        unsupportedArch(
          &"unsupported architecture: {specified}",
          "only armhf and aarch64 are supported"
        )
      )

  if selected != detected.get():
    return LxResult[Architecture].err(archMismatch(specified, $detected.get()))

  return LxResult[Architecture].ok(selected)

when isMainModule:
  proc printUsage() =
    let prog = getAppFilename().extractFilename()
    echo &"Usage: {prog} ROOTFS [ARCH]"
    echo ""
    echo "Examples:"
    echo &"  {prog} ./rootfs"
    echo &"  {prog} ./rootfs aarch64"
    echo &"  {prog} ./rootfs armhf"

  var rootfs = ""
  var arch = ""

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if rootfs.len == 0:
        rootfs = key
      elif arch.len == 0:
        arch = key
      else:
        stderr.writeLine(&"unexpected argument: {key}")
        printUsage()
        quit(1)
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        printUsage()
        quit(0)
      else:
        stderr.writeLine(&"unknown option: {key}")
        printUsage()
        quit(1)
    of cmdEnd:
      discard

  if rootfs.len == 0:
    printUsage()
    quit(1)

  let validation = validateRootfsBasic(rootfs)
  if validation.isErr:
    stderr.writeLine(validation.error().displayMessage())
    quit(validation.error().exitCode())

  let detected = detectRootfsArch(rootfs)
  if detected.isErr:
    stderr.writeLine(detected.error().displayMessage())
    quit(detected.error().exitCode())

  echo &"Detected architecture: {detected.get()}"

  if arch.len > 0:
    let resolved = resolveArchitecture(rootfs, arch)
    if resolved.isErr:
      stderr.writeLine(resolved.error().displayMessage())
      quit(resolved.error().exitCode())

    echo &"Specified architecture matches: {resolved.get()}"
