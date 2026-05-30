# Rebuild support for lxcpkg.
#
# This step extracts a base .lxcpkg and a .lxcdev archive, reads their
# manifests, and verifies that the development archive matches the base image.
# The actual overlay merge and package creation are added by later steps.

import std/os
import std/strformat
import std/strutils

import results

import archive
import devarchive
import errors
import manifest
import types

proc invalidRebuildInput(message: string; detail = ""): LxError =
  result = newError(ekInvalidManifest, message, detail)

proc isSafeRelativeArchivePath(path: string): bool =
  let normalized = path.replace('\\', '/')
  if normalized.len == 0:
    return false

  if normalized.startsWith("/"):
    return false

  for part in normalized.split('/'):
    if part.len == 0 or part == "." or part == "..":
      return false

  result = true

proc checkedArchivePath(baseDir, archivePath, description: string): LxResult[string] =
  if not isSafeRelativeArchivePath(archivePath):
    return LxResult[string].err(
      invalidRebuildInput(&"unsafe {description} path", archivePath)
    )

  result = LxResult[string].ok(baseDir / archivePath)

proc verifyFileSha256(path, expectedSha256, description: string): LxResult[void] =
  if not fileExists(path):
    return LxResult[void].err(ioError(&"{description} does not exist", path))

  let actual = sha256File(path)
  if actual.isErr:
    return LxResult[void].err(actual.error())

  if actual.get().toLowerAscii() != expectedSha256.toLowerAscii():
    return LxResult[void].err(
      invalidRebuildInput(
        &"{description} SHA256 mismatch",
        &"expected={expectedSha256}, actual={actual.get()}"
      )
    )

  result = LxResult[void].ok()

proc verifyManifestCompatibility(
    packageManifest: PackageManifest,
    devManifest: DevArchiveManifest
): LxResult[void] =
  if devManifest.dataMountsIncluded:
    return LxResult[void].err(
      invalidRebuildInput("lxcdev archives with data mounts are not supported yet")
    )

  if packageManifest.name != devManifest.packageName:
    return LxResult[void].err(
      invalidRebuildInput(
        "package name mismatch",
        &"base={packageManifest.name}, lxcdev={devManifest.packageName}"
      )
    )

  if packageManifest.version != devManifest.version:
    return LxResult[void].err(
      invalidRebuildInput(
        "package version mismatch",
        &"base={packageManifest.version}, lxcdev={devManifest.version}"
      )
    )

  if packageManifest.arch != devManifest.arch:
    return LxResult[void].err(
      invalidRebuildInput(
        "package architecture mismatch",
        &"base={packageManifest.arch}, lxcdev={devManifest.arch}"
      )
    )

  if packageManifest.image.file != devManifest.base.imageFile:
    return LxResult[void].err(
      invalidRebuildInput(
        "base image file mismatch",
        &"base={packageManifest.image.file}, lxcdev={devManifest.base.imageFile}"
      )
    )

  if packageManifest.image.sha256.toLowerAscii() != devManifest.base.imageSha256.toLowerAscii():
    return LxResult[void].err(
      invalidRebuildInput(
        "base image SHA256 mismatch",
        &"base={packageManifest.image.sha256}, lxcdev={devManifest.base.imageSha256}"
      )
    )

  result = LxResult[void].ok()

proc prepareRebuildInputs*(
    basePackageFile, devArchiveFile, workDir: string,
    verbose = false
): LxResult[RebuildInputPaths] =
  if basePackageFile.len == 0:
    return LxResult[RebuildInputPaths].err(missingArgument("--base"))

  if devArchiveFile.len == 0:
    return LxResult[RebuildInputPaths].err(missingArgument("--dev"))

  if workDir.len == 0:
    return LxResult[RebuildInputPaths].err(invalidArgument("work directory must not be empty"))

  let baseDir = workDir / "base"
  let devDir = workDir / "dev"

  let extractBase = extractZipArchive(basePackageFile, baseDir, verbose)
  if extractBase.isErr:
    return LxResult[RebuildInputPaths].err(extractBase.error())

  let extractDev = extractZipArchive(devArchiveFile, devDir, verbose)
  if extractDev.isErr:
    return LxResult[RebuildInputPaths].err(extractDev.error())

  let baseManifestPath = baseDir / manifestFileName
  let packageManifest = readManifest(baseManifestPath)
  if packageManifest.isErr:
    return LxResult[RebuildInputPaths].err(packageManifest.error())

  let devManifestPath = devDir / lxcDevArchiveManifestFileName
  let devManifest = readDevArchiveManifest(devManifestPath)
  if devManifest.isErr:
    return LxResult[RebuildInputPaths].err(devManifest.error())

  let compatibility = verifyManifestCompatibility(packageManifest.get(), devManifest.get())
  if compatibility.isErr:
    return LxResult[RebuildInputPaths].err(compatibility.error())

  let baseImagePath = checkedArchivePath(baseDir, packageManifest.get().image.file, "base image")
  if baseImagePath.isErr:
    return LxResult[RebuildInputPaths].err(baseImagePath.error())

  let baseHash = verifyFileSha256(
    baseImagePath.get(),
    packageManifest.get().image.sha256,
    "base image"
  )
  if baseHash.isErr:
    return LxResult[RebuildInputPaths].err(baseHash.error())

  let snapshotPath = checkedArchivePath(devDir, devManifest.get().snapshot.file, "snapshot")
  if snapshotPath.isErr:
    return LxResult[RebuildInputPaths].err(snapshotPath.error())

  let snapshotHash = verifyFileSha256(
    snapshotPath.get(),
    devManifest.get().snapshot.sha256,
    "overlay snapshot"
  )
  if snapshotHash.isErr:
    return LxResult[RebuildInputPaths].err(snapshotHash.error())

  result = LxResult[RebuildInputPaths].ok(RebuildInputPaths(
    baseDir: baseDir,
    devDir: devDir,
    baseManifestPath: baseManifestPath,
    baseImagePath: baseImagePath.get(),
    devManifestPath: devManifestPath,
    snapshotPath: snapshotPath.get(),
    packageManifest: packageManifest.get(),
    devManifest: devManifest.get()
  ))
