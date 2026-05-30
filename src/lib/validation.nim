# Validation and parsing for lxcpkg build options.

import std/strformat
import std/strutils

when isMainModule:
  import std/os
  import std/parseopt

import results

import accounts
import errors
import types

const
  allowedDataMountModes = [
    "0700",
    "0750",
    "0755",
    "0770",
    "0775"
  ]

proc isNameChar(c: char): bool =
  result = c.isAlphaNumeric or c == '_' or c == '.' or c == '-'

proc validateSimpleName*(kind, name: string): LxResult[void] =
  if name.len == 0:
    return LxResult[void].err(invalidDataMount(&"{kind} must not be empty"))

  for c in name:
    if not isNameChar(c):
      return LxResult[void].err(
        invalidDataMount(
          &"invalid {kind}",
          &"{name}: only A-Z, a-z, 0-9, '_', '.', '-' are allowed"
        )
      )

  if name == "." or name == "..":
    return LxResult[void].err(invalidDataMount(&"invalid {kind}", name))

  result = LxResult[void].ok()

proc pathHasDotDot(path: string): bool =
  for part in path.split('/'):
    if part == "..":
      return true

  result = false

proc validateDataMountTarget*(target: string): LxResult[void] =
  if target.len == 0:
    return LxResult[void].err(invalidDataMount("data mount target must not be empty"))

  if not target.startsWith("/"):
    return LxResult[void].err(
      invalidDataMount("data mount target must be an absolute path", target)
    )

  if target == "/":
    return LxResult[void].err(invalidDataMount("data mount target is not allowed", target))

  if target.contains("//"):
    return LxResult[void].err(
      invalidDataMount("data mount target must not contain empty path elements", target)
    )

  if pathHasDotDot(target):
    return LxResult[void].err(
      invalidDataMount("data mount target must not contain '..'", target)
    )

  let allowed =
    target.startsWith("/opt/") or
    target.startsWith("/var/lib/") or
    target.startsWith("/home/")

  if not allowed:
    return LxResult[void].err(
      invalidDataMount(
        "data mount target is outside allowed directories",
        "allowed prefixes: /opt/, /var/lib/, /home/"
      )
    )

  result = LxResult[void].ok()

proc allowedDataMountModesText(): string =
  result = allowedDataMountModes.join(", ")

proc normalizeMode*(mode: string): LxResult[string] =
  let text = mode.strip()
  let normalized =
    if text.len == 0:
      defaultDataMountMode
    elif text.len == 3 and text.allCharsInSet({'0'..'7'}):
      "0" & text
    else:
      text

  if normalized.len != 4 or not normalized.startsWith("0"):
    return LxResult[string].err(
      invalidDataMount("invalid data mount mode", mode)
    )

  if not normalized.allCharsInSet({'0'..'7'}):
    return LxResult[string].err(
      invalidDataMount("invalid data mount mode", mode)
    )

  for allowed in allowedDataMountModes:
    if normalized == allowed:
      return LxResult[string].ok(normalized)

  let allowedModes = allowedDataMountModesText()
  result = LxResult[string].err(
    invalidDataMount(
      "unsupported data mount mode",
      &"{normalized}: allowed modes are {allowedModes}"
    )
  )

proc parseDataMountSpec*(text: string; rootfsAccounts: RootfsAccounts): LxResult[DataMount] =
  let parts = text.split(':')
  if parts.len < 2 or parts.len > 5:
    return LxResult[DataMount].err(
      invalidDataMount(
        "invalid data mount specification",
        "expected name:target[:uid-or-user[:gid-or-group[:mode]]]"
      )
    )

  let name = parts[0].strip()
  let target = parts[1].strip()
  let uidText = if parts.len >= 3: parts[2].strip() else: ""
  let gidText = if parts.len >= 4: parts[3].strip() else: ""
  let modeText = if parts.len >= 5: parts[4].strip() else: ""

  let nameCheck = validateSimpleName("data mount name", name)
  if nameCheck.isErr:
    return LxResult[DataMount].err(nameCheck.error())

  let targetCheck = validateDataMountTarget(target)
  if targetCheck.isErr:
    return LxResult[DataMount].err(targetCheck.error())

  let uid = resolveUserId(rootfsAccounts, uidText)
  if uid.isErr:
    return LxResult[DataMount].err(uid.error())

  let gid = resolveGroupId(rootfsAccounts, gidText)
  if gid.isErr:
    return LxResult[DataMount].err(gid.error())

  let mode = normalizeMode(modeText)
  if mode.isErr:
    return LxResult[DataMount].err(mode.error())

  result = LxResult[DataMount].ok(DataMount(
    name: name,
    target: target,
    uid: uid.get(),
    gid: gid.get(),
    mode: mode.get()
  ))

proc parseDataMountSpecs*(specs: seq[string]; rootfsAccounts: RootfsAccounts): LxResult[seq[DataMount]] =
  var mounts: seq[DataMount] = @[]

  for spec in specs:
    let parsed = parseDataMountSpec(spec, rootfsAccounts)
    if parsed.isErr:
      return LxResult[seq[DataMount]].err(parsed.error())

    let mount = parsed.get()
    for existing in mounts:
      if existing.name == mount.name:
        return LxResult[seq[DataMount]].err(
          invalidDataMount("duplicate data mount name", mount.name)
        )

      if existing.target == mount.target:
        return LxResult[seq[DataMount]].err(
          invalidDataMount("duplicate data mount target", mount.target)
        )

    mounts.add(mount)

  result = LxResult[seq[DataMount]].ok(mounts)

when isMainModule:
  proc printUsage() =
    let prog = getAppFilename().extractFilename()
    echo &"Usage: {prog} ROOTFS DATA_SPEC..."
    echo ""
    echo "Examples:"
    echo &"  {prog} ./rootfs appdata:/var/lib/testapp:user1:user1:0775"
    echo &"  {prog} ./rootfs work:/opt/testapp-data:0:0:0755"

  var rootfs = ""
  var specs: seq[string] = @[]

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if rootfs.len == 0:
        rootfs = key
      else:
        specs.add(key)
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

  if rootfs.len == 0 or specs.len == 0:
    printUsage()
    quit(1)

  let loadedAccounts = loadRootfsAccounts(rootfs)
  if loadedAccounts.isErr:
    stderr.writeLine(loadedAccounts.error().displayMessage())
    quit(loadedAccounts.error().exitCode())

  let mounts = parseDataMountSpecs(specs, loadedAccounts.get())
  if mounts.isErr:
    stderr.writeLine(mounts.error().displayMessage())
    quit(mounts.error().exitCode())

  for mount in mounts.get():
    echo &"{mount.name}: target={mount.target}, uid={mount.uid}, gid={mount.gid}, mode={mount.mode}"
