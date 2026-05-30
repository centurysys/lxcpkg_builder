# Squashfs image creation.
#
# This module wraps the external mksquashfs command. It does not modify the
# source rootfs directory. Cache-like paths are excluded from the generated
# squashfs image by default.

import std/os
import std/osproc
import std/streams
import std/strutils

when isMainModule:
  import std/parseopt
  import std/strformat

import results

import errors
import types

const
  defaultSquashfsExcludes* = [
    "var/cache/apt/archives/*",
    "var/cache/apt/*",
    "var/lib/apt/lists/*",
    "var/tmp/*",
    "var/run/*",
    "run/*",
    "tmp/*",
    "usr/lib/modules/*",
    "lib/modules/*",
    "root/.bash_history",
    "home/user1/.bash_history",
    "usr/bin/qemu-arm-static",
    "boot/*"
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

proc compressionArgs(compression: Compression): seq[string] =
  result = @["-comp", $compression]

  if compression == compZstd:
    result.add("-Xcompression-level")
    result.add("19")

proc makeSquashfsArgs*(opts: SquashfsOptions): seq[string] =
  result = @[
    opts.sourceDir,
    opts.imageFile
  ]

  result.add(compressionArgs(opts.compression))
  result.add("-b")
  result.add(opts.blockSize)
  result.add("-noappend")
  result.add("-wildcards")
  result.add("-e")

  for pattern in defaultSquashfsExcludes:
    result.add(pattern)

  for pattern in opts.extraExcludes:
    result.add(pattern)

proc makeSquashfs*(opts: SquashfsOptions): LxResult[void] =
  if opts.sourceDir.len == 0:
    return LxResult[void].err(missingArgument("--rootfs"))

  if opts.imageFile.len == 0:
    return LxResult[void].err(invalidArgument("squashfs output path must not be empty"))

  if not dirExists(opts.sourceDir):
    return LxResult[void].err(
      invalidRootfs("source rootfs directory does not exist", opts.sourceDir)
    )

  let tool = findTool("mksquashfs")
  if tool.isErr:
    return LxResult[void].err(tool.error())

  let args = makeSquashfsArgs(opts)
  result = runCommand(tool.get(), args, opts.verbose)

when isMainModule:
  proc printUsage() =
    let prog = getAppFilename().extractFilename()
    echo &"Usage: {prog} SOURCEDIR IMGFILE [COMPRESSION] [BLKSIZE]"
    echo ""
    echo "Arguments:"
    echo "  SOURCEDIR     Source rootfs directory"
    echo "  IMGFILE       Output squashfs image file"
    echo "  COMPRESSION   zstd, xz, gzip, lz4, lzo (default: zstd)"
    echo "  BLKSIZE       Squashfs block size (default: 1M)"
    echo ""
    echo "Examples:"
    echo &"  {prog} rootfs rootfs.sqfs"
    echo &"  {prog} rootfs rootfs.sqfs zstd 1M"

  proc parseCompressionForTest(text: string): LxResult[Compression] =
    case text
    of "zstd":
      result = LxResult[Compression].ok(compZstd)
    of "xz":
      result = LxResult[Compression].ok(compXz)
    of "gzip":
      result = LxResult[Compression].ok(compGzip)
    of "lz4":
      result = LxResult[Compression].ok(compLz4)
    of "lzo":
      result = LxResult[Compression].ok(compLzo)
    else:
      result = LxResult[Compression].err(
        invalidArgument("unsupported compression", text)
      )

  var args: seq[string] = @[]

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      args.add(key)
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

  if args.len < 2 or args.len > 4:
    printUsage()
    quit(1)

  let compression =
    if args.len >= 3:
      let parsed = parseCompressionForTest(args[2])
      if parsed.isErr:
        stderr.writeLine(parsed.error().displayMessage())
        quit(parsed.error().exitCode())
      parsed.get()
    else:
      defaultCompression

  let blockSize =
    if args.len >= 4:
      args[3]
    else:
      defaultBlockSize

  let opts = SquashfsOptions(
    sourceDir: args[0],
    imageFile: args[1],
    compression: compression,
    blockSize: blockSize,
    extraExcludes: @[],
    verbose: true
  )

  let squashResult = makeSquashfs(opts)
  if squashResult.isErr:
    stderr.writeLine(squashResult.error().displayMessage())
    quit(squashResult.error().exitCode())
