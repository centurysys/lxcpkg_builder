# Common types for lxcpkg.
#
# This module intentionally contains data-only definitions and small
# conversion helpers. Validation and filesystem operations should live in
# separate modules.

import std/strformat

type
  RootfsMode* = enum
    rmPersistent = "persistent"
    rmVolatile = "volatile"
    rmSnapshot = "snapshot"

  Architecture* = enum
    archArmhf = "armhf"
    archAarch64 = "aarch64"

  Compression* = enum
    compZstd = "zstd"
    compXz = "xz"
    compGzip = "gzip"
    compLz4 = "lz4"
    compLzo = "lzo"

  DataMount* = object
    ## A persistent bind mount described in manifest.json.
    ##
    ## uid/gid/mode are already resolved and normalized:
    ## - uid/gid are numeric IDs used inside the target rootfs.
    ## - mode is a 4-digit octal string such as "0755" or "0775".
    name*: string
    target*: string
    uid*: int
    gid*: int
    mode*: string

  ImageInfo* = object
    file*: string
    sha256*: string

  PackageManifest* = object
    packageId*: string
    name*: string
    version*: string
    arch*: Architecture
    rootfsMode*: RootfsMode
    image*: ImageInfo
    dataMounts*: seq[DataMount]

  BuildOptions* = object
    ## Fully resolved options used by the build step.
    ##
    ## CLI parsing and interactive prompts may fill a separate draft object
    ## first. BuildOptions should be validated enough that the build module can
    ## proceed without asking questions.
    rootfsDir*: string
    outputFile*: string
    packageId*: string
    name*: string
    version*: string
    arch*: Architecture
    rootfsMode*: RootfsMode
    dataMounts*: seq[DataMount]
    compression*: Compression
    blockSize*: string
    extraExcludes*: seq[string]
    nonInteractive*: bool
    force*: bool
    verbose*: bool
    keepWorkdir*: bool

  AccountUser* = object
    name*: string
    uid*: int
    gid*: int

  AccountGroup* = object
    name*: string
    gid*: int

  RootfsAccounts* = object
    users*: seq[AccountUser]
    groups*: seq[AccountGroup]

  SquashfsOptions* = object
    sourceDir*: string
    imageFile*: string
    compression*: Compression
    blockSize*: string
    extraExcludes*: seq[string]
    verbose*: bool

  ArchiveOptions* = object
    manifestFile*: string
    imageFile*: string
    outputFile*: string
    force*: bool
    verbose*: bool

const
  defaultVersion* = "1.0.0"
  defaultRootfsMode* = rmVolatile
  defaultCompression* = compZstd
  defaultBlockSize* = "1M"
  defaultDataMountUid* = 0
  defaultDataMountGid* = 0
  defaultDataMountMode* = "0755"
  rootfsImageFileName* = "rootfs.sqfs"
  manifestFileName* = "manifest.json"

proc `$`*(mount: DataMount): string =
  result = &"{mount.name}:{mount.target}:{mount.uid}:{mount.gid}:{mount.mode}"

proc defaultPackageId*(name: string): string =
  result = &"com.example.{name}"
