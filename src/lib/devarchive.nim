# .lxcdev development archive manifest parsing.
#
# The archive extraction and rebuild steps live in the rebuild module. This
# module only understands lxcdev-manifest.json so the format can be validated
# independently.

import std/json
import std/os
import results

import errors
import types

proc invalidManifest(message: string; detail = ""): LxError =
  result = newError(ekInvalidManifest, message, detail)

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

proc optionalString(node: JsonNode; key: string): LxResult[string] =
  if not node.hasKey(key):
    return LxResult[string].ok("")

  let child = node[key]
  if child.kind != JString:
    return LxResult[string].err(invalidManifest("invalid string", key))

  result = LxResult[string].ok(child.getStr())

proc optionalInt64(node: JsonNode; key: string): LxResult[int64] =
  if not node.hasKey(key):
    return LxResult[int64].ok(0'i64)

  let child = node[key]
  if child.kind != JInt:
    return LxResult[int64].err(invalidManifest("invalid integer", key))

  result = LxResult[int64].ok(child.getBiggestInt())

proc optionalBool(node: JsonNode; key: string; defaultValue: bool): LxResult[bool] =
  if not node.hasKey(key):
    return LxResult[bool].ok(defaultValue)

  let child = node[key]
  if child.kind != JBool:
    return LxResult[bool].err(invalidManifest("invalid boolean", key))

  result = LxResult[bool].ok(child.getBool())

proc baseInfoFromJson(node: JsonNode): LxResult[DevArchiveBaseInfo] =
  let imageFile = requireString(node, "imageFile")
  if imageFile.isErr:
    return LxResult[DevArchiveBaseInfo].err(imageFile.error())

  let imageSha256 = requireString(node, "imageSha256")
  if imageSha256.isErr:
    return LxResult[DevArchiveBaseInfo].err(imageSha256.error())

  let installedImageFile = optionalString(node, "installedImageFile")
  if installedImageFile.isErr:
    return LxResult[DevArchiveBaseInfo].err(installedImageFile.error())

  let installedImageSha256 = optionalString(node, "installedImageSha256")
  if installedImageSha256.isErr:
    return LxResult[DevArchiveBaseInfo].err(installedImageSha256.error())

  result = LxResult[DevArchiveBaseInfo].ok(DevArchiveBaseInfo(
    imageFile: imageFile.get(),
    imageSha256: imageSha256.get(),
    installedImageFile: installedImageFile.get(),
    installedImageSha256: installedImageSha256.get()
  ))

proc snapshotInfoFromJson(node: JsonNode): LxResult[DevArchiveSnapshotInfo] =
  let file = requireString(node, "file")
  if file.isErr:
    return LxResult[DevArchiveSnapshotInfo].err(file.error())

  let sha256 = requireString(node, "sha256")
  if sha256.isErr:
    return LxResult[DevArchiveSnapshotInfo].err(sha256.error())

  let sizeBytes = optionalInt64(node, "sizeBytes")
  if sizeBytes.isErr:
    return LxResult[DevArchiveSnapshotInfo].err(sizeBytes.error())

  result = LxResult[DevArchiveSnapshotInfo].ok(DevArchiveSnapshotInfo(
    file: file.get(),
    sha256: sha256.get(),
    sizeBytes: sizeBytes.get()
  ))

proc filesInfoFromJson(node: JsonNode): LxResult[DevArchiveFilesInfo] =
  let packageManifest = requireString(node, "packageManifest")
  if packageManifest.isErr:
    return LxResult[DevArchiveFilesInfo].err(packageManifest.error())

  let instanceMetadata = requireString(node, "instanceMetadata")
  if instanceMetadata.isErr:
    return LxResult[DevArchiveFilesInfo].err(instanceMetadata.error())

  let lxcConfig = requireString(node, "lxcConfig")
  if lxcConfig.isErr:
    return LxResult[DevArchiveFilesInfo].err(lxcConfig.error())

  result = LxResult[DevArchiveFilesInfo].ok(DevArchiveFilesInfo(
    packageManifest: packageManifest.get(),
    instanceMetadata: instanceMetadata.get(),
    lxcConfig: lxcConfig.get()
  ))

proc devArchiveManifestFromJson*(node: JsonNode): LxResult[DevArchiveManifest] =
  if node.kind != JObject:
    return LxResult[DevArchiveManifest].err(invalidManifest("invalid lxcdev manifest", "expected object"))

  let format = requireString(node, "format")
  if format.isErr:
    return LxResult[DevArchiveManifest].err(format.error())

  if format.get() != lxcDevArchiveFormat:
    return LxResult[DevArchiveManifest].err(
      invalidManifest("unsupported lxcdev manifest format", format.get())
    )

  let instanceName = requireString(node, "instanceName")
  if instanceName.isErr:
    return LxResult[DevArchiveManifest].err(instanceName.error())

  let packageName = requireString(node, "packageName")
  if packageName.isErr:
    return LxResult[DevArchiveManifest].err(packageName.error())

  let version = requireString(node, "version")
  if version.isErr:
    return LxResult[DevArchiveManifest].err(version.error())

  let archText = requireString(node, "arch")
  if archText.isErr:
    return LxResult[DevArchiveManifest].err(archText.error())

  let arch = parseArchitecture(archText.get())
  if arch.isErr:
    return LxResult[DevArchiveManifest].err(arch.error())

  let rootfsModeText = requireString(node, "rootfsMode")
  if rootfsModeText.isErr:
    return LxResult[DevArchiveManifest].err(rootfsModeText.error())

  let rootfsMode = parseRootfsMode(rootfsModeText.get())
  if rootfsMode.isErr:
    return LxResult[DevArchiveManifest].err(rootfsMode.error())

  let baseNode = requireObject(node, "base")
  if baseNode.isErr:
    return LxResult[DevArchiveManifest].err(baseNode.error())

  let base = baseInfoFromJson(baseNode.get())
  if base.isErr:
    return LxResult[DevArchiveManifest].err(base.error())

  let snapshotNode = requireObject(node, "snapshot")
  if snapshotNode.isErr:
    return LxResult[DevArchiveManifest].err(snapshotNode.error())

  let snapshot = snapshotInfoFromJson(snapshotNode.get())
  if snapshot.isErr:
    return LxResult[DevArchiveManifest].err(snapshot.error())

  let filesNode = requireObject(node, "files")
  if filesNode.isErr:
    return LxResult[DevArchiveManifest].err(filesNode.error())

  let files = filesInfoFromJson(filesNode.get())
  if files.isErr:
    return LxResult[DevArchiveManifest].err(files.error())

  let dataMountsIncluded = optionalBool(node, "dataMountsIncluded", false)
  if dataMountsIncluded.isErr:
    return LxResult[DevArchiveManifest].err(dataMountsIncluded.error())

  result = LxResult[DevArchiveManifest].ok(DevArchiveManifest(
    format: format.get(),
    instanceName: instanceName.get(),
    packageName: packageName.get(),
    version: version.get(),
    arch: arch.get(),
    rootfsMode: rootfsMode.get(),
    base: base.get(),
    snapshot: snapshot.get(),
    files: files.get(),
    dataMountsIncluded: dataMountsIncluded.get()
  ))

proc readDevArchiveManifest*(path: string): LxResult[DevArchiveManifest] =
  if not fileExists(path):
    return LxResult[DevArchiveManifest].err(ioError("lxcdev manifest file does not exist", path))

  let node =
    try:
      parseFile(path)
    except JsonParsingError as e:
      return LxResult[DevArchiveManifest].err(invalidManifest("failed to parse lxcdev manifest", e.msg))
    except IOError as e:
      return LxResult[DevArchiveManifest].err(ioError("failed to read lxcdev manifest", e.msg))
    except OSError as e:
      return LxResult[DevArchiveManifest].err(ioError("failed to read lxcdev manifest", e.msg))

  result = devArchiveManifestFromJson(node)
