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
    "root/.cache"
  ]

  # Log files should not be part of release packages, but package post-install
  # scripts often create service-specific log directories that init scripts do
  # not recreate. Keep the /var/log directory tree while removing regular log
  # files and symlinks.
  logCleanupDirs* = [
    "var/log"
  ]

  # Safe language/runtime caches. These are package-manager or bytecode caches
  # generated during image preparation and are not the application payload
  # itself. Directories such as node_modules, venv, vendor, build, target,
  # *.o, and *.a are intentionally not included here.
  languageCleanupDirs* = [
    "root/.npm",
    "root/.pnpm-store",
    "root/.composer/cache"
  ]

  homeLanguageCleanupSubdirs* = [
    ".cache/pip",
    ".cache/pypoetry",
    ".cache/yarn",
    ".cache/pnpm",
    ".npm",
    ".pnpm-store",
    ".composer/cache"
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
    "root/.npm",
    "root/.pnpm-store",
    "root/.composer/cache",
    "root/.composer",
    "tmp",
    "var/tmp",
    "run",
    "var/run",
    "var/log",
    "var/cache/apt/archives",
    "var/cache/apt",
    "var/lib/apt/lists"
  ]

  # Full rootfs packages should keep conventional runtime directories such as
  # /tmp, /var/tmp, /run, and /var/log even when their contents were cleaned.
  # Prune only cache/artifact directories that are safe to recreate.
  prunableRootfsEmptyDirs* = [
    "root/.cache",
    "root/.npm",
    "root/.pnpm-store",
    "root/.composer/cache",
    "root/.composer",
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

proc clearDirFilesOnlyIfPresent(root, relativePath: string; verbose: bool): LxResult[void] =
  let path = checkedPath(root, relativePath)
  if path.isErr:
    return LxResult[void].err(path.error())

  if not dirExists(path.get()):
    return LxResult[void].ok()

  let find = findTool("find")
  if find.isErr:
    return LxResult[void].err(find.error())

  # Remove log files and symlinks, but keep directories. Some packages create
  # service-specific log directories from post-install scripts and their init
  # scripts do not recreate them. Rebuild cleanup must therefore preserve the
  # /var/log directory tree even when log files are removed or archived
  # separately.
  let deleteFiles = @[
    path.get(),
    "-xdev",
    "-mindepth", "1",
    "(", "-type", "f", "-o", "-type", "l", ")",
    "-delete"
  ]

  result = runCommand(find.get(), deleteFiles, verbose)

proc removePythonBytecodeForDelta(root: string; verbose: bool): LxResult[void] =
  let find = findTool("find")
  if find.isErr:
    return LxResult[void].err(find.error())

  # Remove Python bytecode files. They are regenerated at runtime when the
  # rootfs is writable through the runtime overlay, and Python can still run
  # from .py files if bytecode generation is not possible.
  let deleteBytecodeFiles = @[
    root,
    "-xdev",
    "(", "-type", "f", "-o", "-type", "l", ")",
    "(", "-name", "*.pyc", "-o", "-name", "*.pyo", ")",
    "-delete"
  ]

  let bytecodeDeleted = runCommand(find.get(), deleteBytecodeFiles, verbose)
  if bytecodeDeleted.isErr:
    return bytecodeDeleted

  # Remove __pycache__ directories after deleting files. This intentionally
  # targets only Python cache directories, not generic build directories.
  let deletePycacheDirs = @[
    root,
    "-xdev",
    "-type", "d",
    "-name", "__pycache__",
    "-prune",
    "-exec", "rm", "-rf", "{}", "+"
  ]

  result = runCommand(find.get(), deletePycacheDirs, verbose)

proc cleanHomeLanguageCaches(root: string; verbose: bool): LxResult[void] =
  let home = checkedPath(root, "home")
  if home.isErr:
    return LxResult[void].err(home.error())

  if not dirExists(home.get()):
    return LxResult[void].ok()

  try:
    for kind, path in walkDir(home.get()):
      if kind != pcDir:
        continue

      let userName = path.extractFilename()
      if userName.len == 0 or userName == "." or userName == "..":
        continue

      for subdir in homeLanguageCleanupSubdirs:
        let relativePath = "home" / userName / subdir
        let cleaned = clearDirIfPresent(root, relativePath, verbose)
        if cleaned.isErr:
          return cleaned
  except OSError as e:
    return LxResult[void].err(ioError("failed to scan home directories", e.msg))

  result = LxResult[void].ok()

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

proc validateCleanupRoot(root, emptyMessage, missingMessage: string): LxResult[void] =
  if root.len == 0:
    return LxResult[void].err(invalidArgument(emptyMessage))

  if not dirExists(root):
    return LxResult[void].err(ioError(missingMessage, root))

  result = LxResult[void].ok()

proc cleanRootTree(root, emptyMessage, missingMessage: string; verbose: bool): LxResult[void] =
  let valid = validateCleanupRoot(root, emptyMessage, missingMessage)
  if valid.isErr:
    return valid

  for relativePath in aptCleanupDirs:
    let cleaned = clearDirIfPresent(root, relativePath, verbose)
    if cleaned.isErr:
      return cleaned

  for relativePath in genericCleanupDirs:
    let cleaned = clearDirIfPresent(root, relativePath, verbose)
    if cleaned.isErr:
      return cleaned

  for relativePath in logCleanupDirs:
    let cleaned = clearDirFilesOnlyIfPresent(root, relativePath, verbose)
    if cleaned.isErr:
      return cleaned

  for relativePath in languageCleanupDirs:
    let cleaned = clearDirIfPresent(root, relativePath, verbose)
    if cleaned.isErr:
      return cleaned

  let homeCachesCleaned = cleanHomeLanguageCaches(root, verbose)
  if homeCachesCleaned.isErr:
    return homeCachesCleaned

  let pythonBytecodeCleaned = removePythonBytecodeForDelta(root, verbose)
  if pythonBytecodeCleaned.isErr:
    return pythonBytecodeCleaned

  for relativePath in cleanupFiles:
    let cleaned = removeFileIfRegularOrSymlink(root, relativePath, verbose)
    if cleaned.isErr:
      return cleaned

  result = LxResult[void].ok()

proc cleanOverlayForDelta*(upperDir: string; verbose = false): LxResult[void] =
  result = cleanRootTree(
    upperDir,
    "overlay upper directory must not be empty",
    "overlay upper directory does not exist",
    verbose
  )

proc cleanRootfsForPackage*(rootfsDir: string; verbose = false): LxResult[void] =
  result = cleanRootTree(
    rootfsDir,
    "rootfs directory must not be empty",
    "rootfs directory does not exist",
    verbose
  )

proc scrubOverlayForDelta*(upperDir: string; verbose = false): LxResult[void] =
  let valid = validateCleanupRoot(
    upperDir,
    "overlay upper directory must not be empty",
    "overlay upper directory does not exist"
  )
  if valid.isErr:
    return valid

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

proc resetMachineIdForPackage(rootfsDir: string; verbose: bool): LxResult[void] =
  let machineIdPath = checkedPath(rootfsDir, "etc/machine-id")
  if machineIdPath.isErr:
    return LxResult[void].err(machineIdPath.error())

  let removed = removeGlobRegularOrSymlink(rootfsDir, "etc/machine-id", verbose)
  if removed.isErr:
    return removed

  if dirExists(machineIdPath.get()):
    return LxResult[void].err(
      invalidArgument("cannot reset machine-id path because it is a directory", "etc/machine-id")
    )

  let parentDir = machineIdPath.get().parentDir()
  try:
    createDir(parentDir)
    writeFile(machineIdPath.get(), "")
  except IOError as e:
    return LxResult[void].err(ioError("failed to reset /etc/machine-id", e.msg))
  except OSError as e:
    return LxResult[void].err(ioError("failed to reset /etc/machine-id", e.msg))

  result = LxResult[void].ok()

proc scrubRootfsForPackage*(rootfsDir: string; verbose = false): LxResult[void] =
  let valid = validateCleanupRoot(
    rootfsDir,
    "rootfs directory must not be empty",
    "rootfs directory does not exist"
  )
  if valid.isErr:
    return valid

  let machineIdReset = resetMachineIdForPackage(rootfsDir, verbose)
  if machineIdReset.isErr:
    return machineIdReset

  for relativePath in scrubFiles:
    if relativePath == "etc/machine-id":
      continue

    let scrubbed = removeFileIfRegularOrSymlink(rootfsDir, relativePath, verbose)
    if scrubbed.isErr:
      return scrubbed

  for relativePath in scrubFileGlobs:
    let scrubbed = removeGlobRegularOrSymlink(rootfsDir, relativePath, verbose)
    if scrubbed.isErr:
      return scrubbed

  for relativePath in scrubDirs:
    let scrubbed = clearDirIfPresent(rootfsDir, relativePath, verbose)
    if scrubbed.isErr:
      return scrubbed

  result = LxResult[void].ok()

proc pruneEmptyDirsForDelta*(upperDir: string; verbose = false): LxResult[void] =
  let valid = validateCleanupRoot(
    upperDir,
    "overlay upper directory must not be empty",
    "overlay upper directory does not exist"
  )
  if valid.isErr:
    return valid

  for relativePath in prunableEmptyDirs:
    let pruned = removeEmptyDirIfPresent(upperDir, relativePath, verbose)
    if pruned.isErr:
      return pruned

  result = LxResult[void].ok()

proc pruneEmptyDirsForPackage*(rootfsDir: string; verbose = false): LxResult[void] =
  let valid = validateCleanupRoot(
    rootfsDir,
    "rootfs directory must not be empty",
    "rootfs directory does not exist"
  )
  if valid.isErr:
    return valid

  for relativePath in prunableRootfsEmptyDirs:
    let pruned = removeEmptyDirIfPresent(rootfsDir, relativePath, verbose)
    if pruned.isErr:
      return pruned

  result = LxResult[void].ok()
