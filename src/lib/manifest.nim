# Manifest generation, parsing, and SHA256 helpers.

import std/json
import std/os
import std/strformat

when isMainModule:
  import std/parseopt

import results
import checksums/sha2

import errors
import types

proc invalidManifest(message: string; detail = ""): LxError =
  result = newError(ekInvalidManifest, message, detail)

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

proc parseArchitecture(text: string): LxResult[Architecture] =
  case text
  of "armhf":
    result = LxResult[Architecture].ok(archArmhf)
  of "aarch64":
    result = LxResult[Architecture].ok(archAarch64)
  else:
    result = LxResult[Architecture].err(invalidManifest("invalid architecture", text))

proc parseRootfsMode(text: string): LxResult[RootfsMode] =
  case text
  of "persistent":
    result = LxResult[RootfsMode].ok(rmPersistent)
  of "volatile":
    result = LxResult[RootfsMode].ok(rmVolatile)
  of "snapshot":
    result = LxResult[RootfsMode].ok(rmSnapshot)
  else:
    result = LxResult[RootfsMode].err(invalidManifest("invalid rootfs mode", text))

proc requireObject(node: JsonNode; key: string): LxResult[JsonNode] =
  if not node.hasKey(key):
    return LxResult[JsonNode].err(invalidManifest("missing required object", key))

  let child = node[key]
  if child.kind != JObject:
    return LxResult[JsonNode].err(invalidManifest("invalid object", key))

  result = LxResult[JsonNode].ok(child)

proc requireString(node: JsonNode; key: string): LxResult[string] =
  if not node.hasKey(key):
    return LxResult[string].err(invalidManifest("missing required string", key))

  let child = node[key]
  if child.kind != JString:
    return LxResult[string].err(invalidManifest("invalid string", key))

  result = LxResult[string].ok(child.getStr())

proc requireInt(node: JsonNode; key: string): LxResult[int] =
  if not node.hasKey(key):
    return LxResult[int].err(invalidManifest("missing required integer", key))

  let child = node[key]
  if child.kind != JInt:
    return LxResult[int].err(invalidManifest("invalid integer", key))

  result = LxResult[int].ok(child.getInt())

proc optionalInt(node: JsonNode; key: string; defaultValue: int): LxResult[int] =
  if not node.hasKey(key):
    return LxResult[int].ok(defaultValue)

  let child = node[key]
  if child.kind != JInt:
    return LxResult[int].err(invalidManifest("invalid integer", key))

  result = LxResult[int].ok(child.getInt())

proc optionalString(node: JsonNode; key: string; defaultValue: string): LxResult[string] =
  if not node.hasKey(key):
    return LxResult[string].ok(defaultValue)

  let child = node[key]
  if child.kind != JString:
    return LxResult[string].err(invalidManifest("invalid string", key))

  result = LxResult[string].ok(child.getStr())

proc optionalDataMounts(node: JsonNode): LxResult[seq[DataMount]] =
  var mounts: seq[DataMount] = @[]

  if not node.hasKey("dataMounts"):
    return LxResult[seq[DataMount]].ok(mounts)

  let dataMounts = node["dataMounts"]
  if dataMounts.kind != JArray:
    return LxResult[seq[DataMount]].err(invalidManifest("invalid dataMounts", "expected array"))

  for index in 0 ..< dataMounts.len:
    let item = dataMounts[index]
    if item.kind != JObject:
      return LxResult[seq[DataMount]].err(invalidManifest("invalid dataMounts entry", &"index={index}"))

    let name = requireString(item, "name")
    if name.isErr:
      return LxResult[seq[DataMount]].err(name.error())

    let target = requireString(item, "target")
    if target.isErr:
      return LxResult[seq[DataMount]].err(target.error())

    # Older .lxcpkg manifests may only contain name/target for dataMounts.
    # Treat uid/gid/mode as optional for backward compatibility and emit the
    # normalized defaults when the package is rebuilt.
    let uid = optionalInt(item, "uid", defaultDataMountUid)
    if uid.isErr:
      return LxResult[seq[DataMount]].err(uid.error())

    let gid = optionalInt(item, "gid", defaultDataMountGid)
    if gid.isErr:
      return LxResult[seq[DataMount]].err(gid.error())

    let mode = optionalString(item, "mode", defaultDataMountMode)
    if mode.isErr:
      return LxResult[seq[DataMount]].err(mode.error())

    mounts.add(DataMount(
      name: name.get(),
      target: target.get(),
      uid: uid.get(),
      gid: gid.get(),
      mode: mode.get()
    ))

  result = LxResult[seq[DataMount]].ok(mounts)

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

proc manifestFromJson*(node: JsonNode): LxResult[PackageManifest] =
  if node.kind != JObject:
    return LxResult[PackageManifest].err(invalidManifest("invalid manifest", "expected object"))

  let packageId = requireString(node, "packageId")
  if packageId.isErr:
    return LxResult[PackageManifest].err(packageId.error())

  let name = requireString(node, "name")
  if name.isErr:
    return LxResult[PackageManifest].err(name.error())

  let version = requireString(node, "version")
  if version.isErr:
    return LxResult[PackageManifest].err(version.error())

  let archText = requireString(node, "arch")
  if archText.isErr:
    return LxResult[PackageManifest].err(archText.error())

  let arch = parseArchitecture(archText.get())
  if arch.isErr:
    return LxResult[PackageManifest].err(arch.error())

  let rootfsModeText = requireString(node, "rootfsMode")
  if rootfsModeText.isErr:
    return LxResult[PackageManifest].err(rootfsModeText.error())

  let rootfsMode = parseRootfsMode(rootfsModeText.get())
  if rootfsMode.isErr:
    return LxResult[PackageManifest].err(rootfsMode.error())

  let image = requireObject(node, "image")
  if image.isErr:
    return LxResult[PackageManifest].err(image.error())

  let imageFile = requireString(image.get(), "file")
  if imageFile.isErr:
    return LxResult[PackageManifest].err(imageFile.error())

  let imageSha256 = requireString(image.get(), "sha256")
  if imageSha256.isErr:
    return LxResult[PackageManifest].err(imageSha256.error())

  let dataMounts = optionalDataMounts(node)
  if dataMounts.isErr:
    return LxResult[PackageManifest].err(dataMounts.error())

  result = LxResult[PackageManifest].ok(PackageManifest(
    packageId: packageId.get(),
    name: name.get(),
    version: version.get(),
    arch: arch.get(),
    rootfsMode: rootfsMode.get(),
    image: ImageInfo(
      file: imageFile.get(),
      sha256: imageSha256.get()
    ),
    dataMounts: dataMounts.get()
  ))

proc readManifest*(path: string): LxResult[PackageManifest] =
  if not fileExists(path):
    return LxResult[PackageManifest].err(ioError("manifest file does not exist", path))

  let node =
    try:
      parseFile(path)
    except JsonParsingError as e:
      return LxResult[PackageManifest].err(invalidManifest("failed to parse manifest.json", e.msg))
    except IOError as e:
      return LxResult[PackageManifest].err(ioError("failed to read manifest.json", e.msg))
    except OSError as e:
      return LxResult[PackageManifest].err(ioError("failed to read manifest.json", e.msg))

  result = manifestFromJson(node)

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
