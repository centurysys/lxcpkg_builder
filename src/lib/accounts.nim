# Rootfs account database parser.
#
# This module reads <rootfs>/etc/passwd and <rootfs>/etc/group and resolves
# user/group names used by data mount specifications. It does not modify the
# rootfs.

import std/os
import std/strformat
import std/strutils

when isMainModule:
  import std/parseopt

import results

import errors
import types

proc parseId(text: string; fieldName, line: string): LxResult[int] =
  try:
    let value = parseInt(text)
    if value < 0 or value > 65535:
      return LxResult[int].err(
        invalidRootfs(
          &"{fieldName} is out of range",
          &"{text} in line: {line}"
        )
      )

    return LxResult[int].ok(value)
  except ValueError:
    return LxResult[int].err(
      invalidRootfs(
        &"{fieldName} is not a valid integer",
        &"{text} in line: {line}"
      )
    )

proc parsePasswdLine(line: string): LxResult[AccountUser] =
  let parts = line.split(':')
  if parts.len < 7:
    return LxResult[AccountUser].err(
      invalidRootfs("invalid passwd entry", line)
    )

  let uid = parseId(parts[2], "uid", line)
  if uid.isErr:
    return LxResult[AccountUser].err(uid.error())

  let gid = parseId(parts[3], "gid", line)
  if gid.isErr:
    return LxResult[AccountUser].err(gid.error())

  result = LxResult[AccountUser].ok(AccountUser(
    name: parts[0],
    uid: uid.get(),
    gid: gid.get()
  ))

proc parseGroupLine(line: string): LxResult[AccountGroup] =
  let parts = line.split(':')
  if parts.len < 4:
    return LxResult[AccountGroup].err(
      invalidRootfs("invalid group entry", line)
    )

  let gid = parseId(parts[2], "gid", line)
  if gid.isErr:
    return LxResult[AccountGroup].err(gid.error())

  result = LxResult[AccountGroup].ok(AccountGroup(
    name: parts[0],
    gid: gid.get()
  ))

proc loadRootfsAccounts*(rootfs: string): LxResult[RootfsAccounts] =
  let passwdPath = rootfs / "etc" / "passwd"
  let groupPath = rootfs / "etc" / "group"

  if not fileExists(passwdPath):
    return LxResult[RootfsAccounts].err(
      invalidRootfs("rootfs does not contain etc/passwd", rootfs)
    )

  if not fileExists(groupPath):
    return LxResult[RootfsAccounts].err(
      invalidRootfs("rootfs does not contain etc/group", rootfs)
    )

  var accounts = RootfsAccounts()

  try:
    for rawLine in lines(passwdPath):
      let line = rawLine.strip()
      if line.len == 0 or line.startsWith("#"):
        continue

      let user = parsePasswdLine(line)
      if user.isErr:
        return LxResult[RootfsAccounts].err(user.error())

      accounts.users.add(user.get())

    for rawLine in lines(groupPath):
      let line = rawLine.strip()
      if line.len == 0 or line.startsWith("#"):
        continue

      let group = parseGroupLine(line)
      if group.isErr:
        return LxResult[RootfsAccounts].err(group.error())

      accounts.groups.add(group.get())
  except IOError as e:
    return LxResult[RootfsAccounts].err(
      ioError("failed to read rootfs account database", e.msg)
    )

  result = LxResult[RootfsAccounts].ok(accounts)

proc findUser*(accounts: RootfsAccounts; name: string): LxResult[AccountUser] =
  for user in accounts.users:
    if user.name == name:
      return LxResult[AccountUser].ok(user)

  result = LxResult[AccountUser].err(accountNotFound("user", name))

proc findGroup*(accounts: RootfsAccounts; name: string): LxResult[AccountGroup] =
  for group in accounts.groups:
    if group.name == name:
      return LxResult[AccountGroup].ok(group)

  result = LxResult[AccountGroup].err(accountNotFound("group", name))

proc resolveUserId*(accounts: RootfsAccounts; text: string): LxResult[int] =
  if text.len == 0:
    return LxResult[int].ok(defaultDataMountUid)

  if text.allCharsInSet(Digits):
    let id = parseId(text, "uid", text)
    if id.isErr:
      return id

    return LxResult[int].ok(id.get())

  let user = accounts.findUser(text)
  if user.isErr:
    return LxResult[int].err(user.error())

  result = LxResult[int].ok(user.get().uid)

proc resolveGroupId*(accounts: RootfsAccounts; text: string): LxResult[int] =
  if text.len == 0:
    return LxResult[int].ok(defaultDataMountGid)

  if text.allCharsInSet(Digits):
    let id = parseId(text, "gid", text)
    if id.isErr:
      return id

    return LxResult[int].ok(id.get())

  let group = accounts.findGroup(text)
  if group.isErr:
    return LxResult[int].err(group.error())

  result = LxResult[int].ok(group.get().gid)

when isMainModule:
  proc printUsage() =
    let prog = getAppFilename().extractFilename()
    echo &"Usage: {prog} ROOTFS [USER_OR_UID] [GROUP_OR_GID]"
    echo ""
    echo "Examples:"
    echo &"  {prog} ./rootfs"
    echo &"  {prog} ./rootfs user1 user1"
    echo &"  {prog} ./rootfs 1000 1000"

  var rootfs = ""
  var userName = ""
  var groupName = ""

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if rootfs.len == 0:
        rootfs = key
      elif userName.len == 0:
        userName = key
      elif groupName.len == 0:
        groupName = key
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

  let accounts = loadRootfsAccounts(rootfs)
  if accounts.isErr:
    stderr.writeLine(accounts.error().displayMessage())
    quit(accounts.error().exitCode())

  echo &"Users:  {accounts.get().users.len}"
  echo &"Groups: {accounts.get().groups.len}"

  if userName.len > 0:
    let uid = resolveUserId(accounts.get(), userName)
    if uid.isErr:
      stderr.writeLine(uid.error().displayMessage())
      quit(uid.error().exitCode())

    echo &"User {userName}: {uid.get()}"

  if groupName.len > 0:
    let gid = resolveGroupId(accounts.get(), groupName)
    if gid.isErr:
      stderr.writeLine(gid.error().displayMessage())
      quit(gid.error().exitCode())

    echo &"Group {groupName}: {gid.get()}"
