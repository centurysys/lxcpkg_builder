# Interactive prompt helpers for lxcpkg.

import std/options
import std/strformat
import std/strutils

import results

import errors
import types

proc readPrompt(prompt: string): string =
  stdout.write(prompt)
  stdout.flushFile()
  result = stdin.readLine().strip()

proc promptString*(label: string; default = ""): string =
  if default.len > 0:
    let answer = readPrompt(&"{label} [{default}]: ")
    if answer.len == 0:
      result = default
    else:
      result = answer
  else:
    result = readPrompt(&"{label}: ")

proc promptRequiredString*(label: string; default = ""): LxResult[string] =
  while true:
    let value = promptString(label, default)
    if value.len > 0:
      return LxResult[string].ok(value)

    stderr.writeLine("Value must not be empty.")

proc promptYesNo*(label: string; default = false): bool =
  let suffix =
    if default:
      " [Y/n]: "
    else:
      " [y/N]: "

  while true:
    let answer = readPrompt(label & suffix).toLowerAscii()
    if answer.len == 0:
      return default

    case answer
    of "y", "yes":
      return true
    of "n", "no":
      return false
    else:
      stderr.writeLine("Please answer y or n.")

proc promptRootfsMode*(defaultMode = defaultRootfsMode): RootfsMode =
  echo "Rootfs mode:"
  echo "  1) persistent  - storage-backed rootfs overlay"
  echo "  2) volatile    - tmpfs rootfs overlay, discarded on stop"
  echo "  3) snapshot    - tmpfs rootfs overlay with save/restore support"

  let defaultNumber =
    case defaultMode
    of rmPersistent: "1"
    of rmVolatile: "2"
    of rmSnapshot: "3"

  while true:
    let answer = promptString("Select rootfs mode", defaultNumber)
    case answer
    of "1", "persistent":
      return rmPersistent
    of "2", "volatile":
      return rmVolatile
    of "3", "snapshot":
      return rmSnapshot
    else:
      stderr.writeLine("Please select 1, 2, or 3.")

proc promptDataMountSpecs*(accounts: RootfsAccounts): seq[string] =
  result = @[]

  if not promptYesNo("Add data mount?", false):
    return

  while true:
    let name = promptRequiredString("Data mount name")
    if name.isErr:
      return

    let target = promptRequiredString("Target path in container")
    if target.isErr:
      return

    let owner = promptString("Owner user or uid", "root")
    let groupDefault =
      if owner.len > 0:
        owner
      else:
        "root"

    let group = promptString("Group or gid", groupDefault)
    let mode = promptString("Mode", defaultDataMountMode)

    result.add(&"{name.get()}:{target.get()}:{owner}:{group}:{mode}")

    if not promptYesNo("Add another data mount?", false):
      break

proc maybePromptOption*(value: Option[string]; label: string; default = ""; nonInteractive: bool): LxResult[string] =
  if value.isSome and value.get().len > 0:
    return LxResult[string].ok(value.get())

  if nonInteractive:
    return LxResult[string].err(missingArgument("--" & label.toLowerAscii().replace(" ", "-")))

  result = promptRequiredString(label, default)

proc maybePromptOptional*(value: Option[string]; label: string; default = ""; nonInteractive: bool): string =
  if value.isSome and value.get().len > 0:
    return value.get()

  if nonInteractive:
    return default

  result = promptString(label, default)
