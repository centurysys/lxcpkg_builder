# Manifest generation and SHA256 helpers.

import std/json
import std/os

when isMainModule:
  import std/parseopt
  import std/strformat

import results
import checksums/sha2

import errors
import types

proc sha256File*(path: string): LxResult[string] =
  if not fileExists(path):
    return LxResult[string].err(ioError("file does not exist", path))

  var f: File
  if not open(f, path, fmRead):
    return LxResult[string].err(ioError("failed to open file for SHA256", path))

  defer:
    f.close()

  var hasher = initSha_256()
  var buffer = newString(64 * 1024)

  try:
    while true:
      let n = f.readChars(buffer.toOpenArray(0, buffer.high))
      if n == 0:
        break

      hasher.update(buffer.toOpenArray(0, n - 1))

    result = LxResult[string].ok($hasher.digest())
  except IOError as e:
    result = LxResult[string].err(ioError("failed to calculate SHA256", e.msg))
  except OSError as e:
    result = LxResult[string].err(ioError("failed to calculate SHA256", e.msg))

proc dataMountToJson(mount: DataMount): JsonNode =
  result = %*{
    "name": mount.name,
    "target": mount.target,
    "uid": mount.uid,
    "gid": mount.gid,
    "mode": mount.mode
  }

proc manifestToJson*(manifest: PackageManifest): JsonNode =
  result = %*{
    "packageId": manifest.packageId,
    "name": manifest.name,
    "version": manifest.version,
    "arch": $manifest.arch,
    "rootfsMode": $manifest.rootfsMode,
    "image": {
      "file": manifest.image.file,
      "sha256": manifest.image.sha256
    }
  }

  var mounts = newJArray()
  for mount in manifest.dataMounts:
    mounts.add(dataMountToJson(mount))

  if mounts.len > 0:
    result["dataMounts"] = mounts

proc makeManifest*(buildOpts: BuildOptions; imageSha256: string): PackageManifest =
  result = PackageManifest(
    packageId: buildOpts.packageId,
    name: buildOpts.name,
    version: buildOpts.version,
    arch: buildOpts.arch,
    rootfsMode: buildOpts.rootfsMode,
    image: ImageInfo(
      file: rootfsImageFileName,
      sha256: imageSha256
    ),
    dataMounts: buildOpts.dataMounts
  )

proc writeManifest*(manifest: PackageManifest; path: string): LxResult[void] =
  try:
    writeFile(path, manifestToJson(manifest).pretty() & "\n")
    result = LxResult[void].ok()
  except IOError as e:
    result = LxResult[void].err(ioError("failed to write manifest.json", e.msg))
  except OSError as e:
    result = LxResult[void].err(ioError("failed to write manifest.json", e.msg))

when isMainModule:
  proc printUsage() =
    let prog = getAppFilename().extractFilename()
    echo &"Usage: {prog} FILE"
    echo ""
    echo "Calculate SHA256 of FILE."

  var path = ""

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if path.len == 0:
        path = key
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

  if path.len == 0:
    printUsage()
    quit(1)

  let hash = sha256File(path)
  if hash.isErr:
    stderr.writeLine(hash.error().displayMessage())
    quit(hash.error().exitCode())

  echo hash.get()
