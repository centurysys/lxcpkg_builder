# Cleanup helpers for development overlay snapshots.
#
# These routines are intended to run on an extracted overlayfs upperdir before
# it is packed as a delta squashfs image. They remove cache/log/tmp files that
# are commonly produced while preparing an image, but intentionally preserve
# overlayfs whiteouts and other special filesystem entries.

import std/os
import std/osproc
import std/streams
import std/strutils

import results

import errors

const
  aptCleanupDirs* = [
    "var/cache/apt/archives",
    "var/lib/apt/lists"
  ]

  genericCleanupDirs* = [
    "tmp",
    "var/tmp",
    "run",
    "var/run",
    "var/log",
    "root/.cache"
  ]

  cleanupFiles*: array[0, string] = []

  scrubFiles* = [
    "etc/machine-id",
    "var/lib/dbus/machine-id",
    "root/.bash_history",
    "root/.wget-hsts"
  ]

  scrubDirs* = [
    "root/.cache"
  ]

  scrubFileGlobs* = [
    "etc/ssh/ssh_host_*_key",
    "etc/ssh/ssh_host_*_key.pub"
  ]

  prunableEmptyDirs* = [
    "etc/ssh",
    "root/.cache",
    "tmp",
    "var/tmp",
    "run",
    "var/run",
    "var/log",
    "var/cache/apt/archives",
    "var/cache/apt",
    "var/lib/apt/lists"
  ]

proc findTool(tool: string): LxResult[string] =
  let path = findExe(tool)
  if path.len == 0:
    return LxResult[string].err(externalToolMissing(tool))

  result = LxResult[string].ok(path)

proc formatCommand(command: string; args: seq[string]): string =
  if args.len == 0:
    return command

  result = command & " " & args.join(" ")

proc readProcessOutput(process: Process): LxResult[string] =
  try:
    result = LxResult[string].ok(process.outputStream.readAll())
  except IOError as e:
    result = LxResult[string].err(
      ioError("failed to read external command output", e.msg)
    )

proc runCommand(command: string; args: seq[string]; verbose: bool): LxResult[void] =
  if verbose:
    echo formatCommand(command, args)

  let process =
    try:
      startProcess(
        command,
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
    return LxResult[void].err(
      externalCommandFailed(command, code, output.strip())
    )

  if verbose and output.len > 0:
    stdout.write(output)

  result = LxResult[void].ok()

proc isInsideRoot(root, path: string): bool =
  let rootAbs = absolutePath(root).normalizedPath()
  let pathAbs = absolutePath(path).normalizedPath()

  result = pathAbs == rootAbs or pathAbs.startsWith(rootAbs / "")

proc checkedPath(root, relativePath: string): LxResult[string] =
  if relativePath.len == 0 or relativePath.startsWith("/"):
    return LxResult[string].err(invalidArgument("unsafe cleanup path", relativePath))

  let normalized = relativePath.replace('\\', '/').normalizedPath()
  for part in normalized.split('/'):
    if part == "..":
      return LxResult[string].err(invalidArgument("unsafe cleanup path", relativePath))

  let path = root / normalized
  if not isInsideRoot(root, path):
    return LxResult[string].err(invalidArgument("cleanup path escapes root", relativePath))

  result = LxResult[string].ok(path)

proc removeFileIfRegularOrSymlink(root, relativePath: string; verbose: bool): LxResult[void] =
  let path = checkedPath(root, relativePath)
  if path.isErr:
    return LxResult[void].err(path.error())

  if not fileExists(path.get()):
    return LxResult[void].ok()

  let find = findTool("find")
  if find.isErr:
    return LxResult[void].err(find.error())

  let args = @[
    path.get(),
    "-maxdepth", "0",
    "(", "-type", "f", "-o", "-type", "l", ")",
    "-delete"
  ]

  result = runCommand(find.get(), args, verbose)

proc removeEmptyDirIfPresent(root, relativePath: string; verbose: bool): LxResult[void] =
  let path = checkedPath(root, relativePath)
  if path.isErr:
    return LxResult[void].err(path.error())

  if not dirExists(path.get()):
    return LxResult[void].ok()

  let find = findTool("find")
  if find.isErr:
    return LxResult[void].err(find.error())

  let args = @[
    path.get(),
    "-maxdepth", "0",
    "-type", "d",
    "-empty",
    "-delete"
  ]

  result = runCommand(find.get(), args, verbose)

proc clearDirIfPresent(root, relativePath: string; verbose: bool): LxResult[void] =
  let path = checkedPath(root, relativePath)
  if path.isErr:
    return LxResult[void].err(path.error())

  if not dirExists(path.get()):
    return LxResult[void].ok()

  let find = findTool("find")
  if find.isErr:
    return LxResult[void].err(find.error())

  # Delete regular files and symlinks first. Character-device whiteouts and
  # other special entries are intentionally left in place so base-side files do
  # not reappear when the delta is applied.
  let deleteFiles = @[
    path.get(),
    "-xdev",
    "-mindepth", "1",
    "(", "-type", "f", "-o", "-type", "l", ")",
    "-delete"
  ]

  let filesDeleted = runCommand(find.get(), deleteFiles, verbose)
  if filesDeleted.isErr:
    return filesDeleted

  # Remove empty directories after file deletion. Directories that still contain
  # preserved whiteouts or opaque metadata stay in the upperdir.
  let deleteEmptyDirs = @[
    path.get(),
    "-xdev",
    "-mindepth", "1",
    "-type", "d",
    "-empty",
    "-delete"
  ]

  result = runCommand(find.get(), deleteEmptyDirs, verbose)

proc removeGlobRegularOrSymlink(root, relativePattern: string; verbose: bool): LxResult[void] =
  let slash = relativePattern.rfind('/')
  if slash < 0:
    return LxResult[void].err(invalidArgument("unsafe cleanup glob", relativePattern))

  let dirPart = relativePattern[0 ..< slash]
  let patternPart = relativePattern[slash + 1 .. ^1]

  if patternPart.len == 0 or patternPart.contains('/') or patternPart.contains(".."):
    return LxResult[void].err(invalidArgument("unsafe cleanup glob", relativePattern))

  let dir = checkedPath(root, dirPart)
  if dir.isErr:
    return LxResult[void].err(dir.error())

  if not dirExists(dir.get()):
    return LxResult[void].ok()

  let find = findTool("find")
  if find.isErr:
    return LxResult[void].err(find.error())

  let args = @[
    dir.get(),
    "-maxdepth", "1",
    "(", "-type", "f", "-o", "-type", "l", ")",
    "-name", patternPart,
    "-delete"
  ]

  result = runCommand(find.get(), args, verbose)

proc cleanOverlayForDelta*(upperDir: string; verbose = false): LxResult[void] =
  if upperDir.len == 0:
    return LxResult[void].err(invalidArgument("overlay upper directory must not be empty"))

  if not dirExists(upperDir):
    return LxResult[void].err(ioError("overlay upper directory does not exist", upperDir))

  for relativePath in aptCleanupDirs:
    let cleaned = clearDirIfPresent(upperDir, relativePath, verbose)
    if cleaned.isErr:
      return cleaned

  for relativePath in genericCleanupDirs:
    let cleaned = clearDirIfPresent(upperDir, relativePath, verbose)
    if cleaned.isErr:
      return cleaned

  for relativePath in cleanupFiles:
    let cleaned = removeFileIfRegularOrSymlink(upperDir, relativePath, verbose)
    if cleaned.isErr:
      return cleaned

  result = LxResult[void].ok()

proc scrubOverlayForDelta*(upperDir: string; verbose = false): LxResult[void] =
  if upperDir.len == 0:
    return LxResult[void].err(invalidArgument("overlay upper directory must not be empty"))

  if not dirExists(upperDir):
    return LxResult[void].err(ioError("overlay upper directory does not exist", upperDir))

  for relativePath in scrubFiles:
    let scrubbed = removeFileIfRegularOrSymlink(upperDir, relativePath, verbose)
    if scrubbed.isErr:
      return scrubbed

  for relativePath in scrubFileGlobs:
    let scrubbed = removeGlobRegularOrSymlink(upperDir, relativePath, verbose)
    if scrubbed.isErr:
      return scrubbed

  for relativePath in scrubDirs:
    let scrubbed = clearDirIfPresent(upperDir, relativePath, verbose)
    if scrubbed.isErr:
      return scrubbed

  result = LxResult[void].ok()

proc pruneEmptyDirsForDelta*(upperDir: string; verbose = false): LxResult[void] =
  if upperDir.len == 0:
    return LxResult[void].err(invalidArgument("overlay upper directory must not be empty"))

  if not dirExists(upperDir):
    return LxResult[void].err(ioError("overlay upper directory does not exist", upperDir))

  for relativePath in prunableEmptyDirs:
    let pruned = removeEmptyDirIfPresent(upperDir, relativePath, verbose)
    if pruned.isErr:
      return pruned

  result = LxResult[void].ok()
