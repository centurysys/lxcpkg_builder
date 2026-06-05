# .lxcpkg archive creation.
#
# This module wraps the external zip command. The archive is created with
# manifest.json and rootfs.sqfs at the top level.

import std/os
import std/osproc
import std/streams
import std/strutils

import results

import errors
import types

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

proc runCommand(command: string; args: seq[string]; workingDir: string; verbose: bool): LxResult[void] =
  if verbose:
    echo formatCommand(command, args)

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
    return LxResult[void].err(
      externalCommandFailed(command, code, output.strip())
    )

  if verbose and output.len > 0:
    stdout.write(output)

  result = LxResult[void].ok()

proc checkArchiveOutput*(outputFile: string; force: bool): LxResult[void] =
  if outputFile.len == 0:
    return LxResult[void].err(missingArgument("--output"))

  let outputPath = absolutePath(outputFile)
  if fileExists(outputPath) and not force:
    return LxResult[void].err(outputExists(outputPath))

  result = LxResult[void].ok()



proc ensureArchiveExtension*(path, extension: string): string =
  let stripped = path.strip()
  if stripped.toLowerAscii().endsWith(extension.toLowerAscii()):
    return stripped

  result = stripped & extension

proc extractZipArchive*(archiveFile, outputDir: string; verbose: bool): LxResult[void] =
  if archiveFile.len == 0:
    return LxResult[void].err(missingArgument("archive file"))

  if not fileExists(archiveFile):
    return LxResult[void].err(ioError("archive file does not exist", archiveFile))

  try:
    createDir(outputDir)
  except OSError as e:
    return LxResult[void].err(ioError("failed to create archive extraction directory", e.msg))

  let tool = findTool("unzip")
  if tool.isErr:
    return LxResult[void].err(tool.error())

  let args = @[
    "-q",
    archiveFile,
    "-d",
    outputDir
  ]

  result = runCommand(tool.get(), args, getCurrentDir(), verbose)

proc createArchiveWithImageName*(
    manifestFile, imageFile, imageArchiveName, outputFile: string,
    force, verbose: bool,
    store: bool = false
): LxResult[void] =
  let outputCheck = checkArchiveOutput(outputFile, force)
  if outputCheck.isErr:
    return outputCheck

  if not fileExists(manifestFile):
    return LxResult[void].err(ioError("manifest file does not exist", manifestFile))

  if not fileExists(imageFile):
    return LxResult[void].err(ioError("image file does not exist", imageFile))

  let outputPath = absolutePath(outputFile)
  if fileExists(outputPath) and force:
    try:
      removeFile(outputPath)
    except OSError as e:
      return LxResult[void].err(ioError("failed to remove existing output file", e.msg))

  let workDir = manifestFile.parentDir()
  if workDir.len == 0:
    return LxResult[void].err(ioError("invalid archive working directory", manifestFile))

  if imageFile.parentDir().normalizedPath() != workDir.normalizedPath():
    return LxResult[void].err(
      ioError("manifest and image must be in the same archive working directory")
    )

  let tool = findTool("zip")
  if tool.isErr:
    return LxResult[void].err(tool.error())

  var args = @["-q"]
  if store:
    args.add("-0")
  args.add("-r")
  args.add(outputPath)
  args.add(manifestFileName)
  args.add(imageArchiveName)

  result = runCommand(tool.get(), args, workDir, verbose)

proc createArchive*(opts: ArchiveOptions): LxResult[void] =
  result = createArchiveWithImageName(
    opts.manifestFile,
    opts.imageFile,
    rootfsImageFileName,
    opts.outputFile,
    opts.force,
    opts.verbose
  )
