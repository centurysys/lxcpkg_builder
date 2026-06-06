# Command line interface for lxcpkg.

import std/options
import std/strformat

import argparse
import results

import build
import delta
import download_build
import errors
import rebuild

proc runCli*(): int =
  var status = 0

  var parser = newParser("lxcpkg"):
    help("Build LXC application packages for MAX3xx WebUI")

    command("build"):
      help("Build a .lxcpkg archive from a rootfs directory")

      option("--rootfs", help = "Source rootfs directory")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("--package-id", help = "Package ID, for example com.example.app")
      option("--name", help = "Package name")
      option("--version", help = "Package version")
      option("--arch", choices = @["armhf", "aarch64"], help = "Target architecture")
      option("--rootfs-mode", choices = @["persistent", "volatile", "snapshot"], help = "Initial rootfs overlay mode")
      option("--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("--block-size", default = some("1M"), help = "Squashfs block size")
      option("--data", multiple = true, help = "Data mount: name:target[:uid-or-user[:gid-or-group[:mode]]]")
      option("--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      flag("--non-interactive", help = "Do not prompt for missing values")
      flag("--keep-workdir", help = "Keep temporary build directory after successful build")
      flag("-f", "--force", help = "Overwrite output file")
      flag("-v", "--verbose", help = "Show external commands")

      run:
        let raw = RawBuildOptions(
          rootfs: opts.rootfs_opt,
          output: opts.output_opt,
          packageId: opts.package_id_opt,
          name: opts.name_opt,
          version: opts.version_opt,
          arch: opts.arch_opt,
          rootfsMode: opts.rootfs_mode_opt,
          compression: some(opts.compression),
          blockSize: some(opts.block_size),
          data: opts.data,
          exclude: opts.exclude,
          nonInteractive: opts.non_interactive,
          force: opts.force,
          verbose: opts.verbose,
          keepWorkdir: opts.keep_workdir
        )

        let buildResult = runBuild(raw)
        if buildResult.isErr:
          let e = buildResult.error()
          stderr.writeLine(e.displayMessage())
          status = e.exitCode()


    command("pack-lxc-dir"):
      help("Build a .lxcpkg archive from an LXC directory created by lxc-create")

      option("--lxc-dir", help = "LXC container directory containing config and rootfs")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("--package-id", help = "Package ID, for example com.example.app")
      option("--name", help = "Package name")
      option("--version", help = "Package version")
      option("--arch", choices = @["armhf", "aarch64"], help = "Target architecture")
      option("--rootfs-mode", choices = @["persistent", "volatile", "snapshot"], help = "Initial rootfs overlay mode")
      option("--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("--block-size", default = some("1M"), help = "Squashfs block size")
      option("--data", multiple = true, help = "Data mount: name:target[:uid-or-user[:gid-or-group[:mode]]]")
      option("--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      option("--normalize", default = some("none"), choices = @["none", "product"], help = "Rootfs normalize profile")
      option("--minimize", default = some("none"), choices = @["none", "auto", "alpine", "debian"], help = "Rootfs minimize profile")
      option("--network-mode", default = some("dhcp"), choices = @["dhcp", "host-configured"], help = "Rootfs network startup mode")
      flag("--keep-workdir", help = "Keep temporary build directory after successful build")
      flag("-f", "--force", help = "Overwrite output file")
      flag("-v", "--verbose", help = "Show external commands")

      run:
        let raw = RawPackLxcDirOptions(
          lxcDir: opts.lxc_dir_opt,
          output: opts.output_opt,
          packageId: opts.package_id_opt,
          name: opts.name_opt,
          version: opts.version_opt,
          arch: opts.arch_opt,
          rootfsMode: opts.rootfs_mode_opt,
          compression: some(opts.compression),
          blockSize: some(opts.block_size),
          data: opts.data,
          exclude: opts.exclude,
          normalize: some(opts.normalize),
          minimize: some(opts.minimize),
          networkMode: some(opts.network_mode),
          force: opts.force,
          verbose: opts.verbose,
          keepWorkdir: opts.keep_workdir
        )

        let packResult = runPackLxcDir(raw)
        if packResult.isErr:
          let e = packResult.error()
          stderr.writeLine(e.displayMessage())
          status = e.exitCode()

    command("build-download"):
      help("Download an LXC image with lxc-create -t download and build a .lxcpkg archive")

      option("--dist", help = "Distribution name, for example alpine, debian, ubuntu, fedora")
      option("--release", help = "Distribution release, for example 3.23, trixie, noble, 44")
      option("--arch", choices = @["armhf", "arm64", "aarch64", "armv7", "armv7l"], help = "Target architecture")
      option("--bits", choices = @["32", "64"], help = "Target ARM width; 64 maps to arm64, 32 maps to armhf")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("--package-id", help = "Package ID, for example com.example.app")
      option("--name", help = "Package name")
      option("--version", help = "Package version")
      option("--rootfs-mode", choices = @["persistent", "volatile", "snapshot"], help = "Initial rootfs overlay mode")
      option("--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("--block-size", default = some("1M"), help = "Squashfs block size")
      option("--data", multiple = true, help = "Data mount: name:target[:uid-or-user[:gid-or-group[:mode]]]")
      option("--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      option("--normalize", default = some("product"), choices = @["none", "product"], help = "Rootfs normalize profile")
      option("--minimize", default = some("auto"), choices = @["none", "auto", "alpine", "debian"], help = "Rootfs minimize profile")
      option("--network-mode", default = some("dhcp"), choices = @["dhcp", "host-configured"], help = "Rootfs network startup mode")
      option("--work-dir", help = "Parent directory for temporary download work directory; default is /var/tmp")
      flag("--interactive", help = "Let lxc-download ask for missing distribution/release information")
      flag("--keep-workdir", help = "Keep temporary download/build directory after successful build")
      flag("-f", "--force", help = "Overwrite output file")
      flag("-v", "--verbose", help = "Show external commands")

      run:
        let raw = RawBuildDownloadOptions(
          dist: opts.dist_opt,
          release: opts.release_opt,
          arch: opts.arch_opt,
          bits: opts.bits_opt,
          output: opts.output_opt,
          packageId: opts.package_id_opt,
          name: opts.name_opt,
          version: opts.version_opt,
          rootfsMode: opts.rootfs_mode_opt,
          compression: some(opts.compression),
          blockSize: some(opts.block_size),
          data: opts.data,
          exclude: opts.exclude,
          normalize: some(opts.normalize),
          minimize: some(opts.minimize),
          networkMode: some(opts.network_mode),
          interactive: opts.interactive,
          workDir: opts.work_dir_opt,
          keepWorkdir: opts.keep_workdir,
          force: opts.force,
          verbose: opts.verbose
        )

        let downloadResult = runBuildDownload(raw)
        if downloadResult.isErr:
          let e = downloadResult.error()
          stderr.writeLine(e.displayMessage())
          status = e.exitCode()


    command("delta"):
      help("Build a .lxcdelta archive from a base package and a .lxcdev archive")

      option("--base", help = "Base .lxcpkg file")
      option("--dev", help = "Development .lxcdev archive")
      option("-o", "--output", help = "Output .lxcdelta file")
      option("--version", help = "Package version for delta package")
      option("--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("--block-size", default = some("1M"), help = "Squashfs block size")
      option("--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      flag("--no-clean", help = "Do not remove apt/cache/log/tmp files from the extracted overlay upperdir before creating delta.sqfs")
      flag("--no-scrub", help = "Do not remove machine-id, SSH host keys, shell history, and other instance-specific files before creating delta.sqfs")
      flag("--no-prune-empty-dirs", help = "Do not remove empty cleanup directories after release cleanup")
      flag("--no-release-clean", help = "Disable the default release cleanup; equivalent to --no-clean --no-scrub --no-prune-empty-dirs")
      flag("--keep-workdir", help = "Keep temporary delta directory after successful delta build")
      flag("-f", "--force", help = "Overwrite output file")
      flag("-v", "--verbose", help = "Show external commands")

      run:
        let raw = RawDeltaOptions(
          base: opts.base_opt,
          dev: opts.dev_opt,
          output: opts.output_opt,
          version: opts.version_opt,
          compression: some(opts.compression),
          blockSize: some(opts.block_size),
          exclude: opts.exclude,
          clean: not opts.no_clean and not opts.no_release_clean,
          scrub: not opts.no_scrub and not opts.no_release_clean,
          pruneEmptyDirs: not opts.no_prune_empty_dirs and not opts.no_release_clean,
          force: opts.force,
          verbose: opts.verbose,
          keepWorkdir: opts.keep_workdir
        )

        let deltaResult = runDelta(raw)
        if deltaResult.isErr:
          let e = deltaResult.error()
          stderr.writeLine(e.displayMessage())
          status = e.exitCode()

    command("rebuild"):
      help("Rebuild a .lxcpkg archive from a base package and a .lxcdev archive")

      option("--base", help = "Base .lxcpkg file")
      option("--dev", help = "Development .lxcdev archive")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("--version", help = "Package version for rebuilt package")
      option("--rootfs-mode", choices = @["persistent", "volatile", "snapshot"], help = "Rootfs overlay mode for rebuilt package")
      option("--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("--block-size", default = some("1M"), help = "Squashfs block size")
      option("--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      flag("--keep-workdir", help = "Keep temporary rebuild directory after successful rebuild")
      flag("-f", "--force", help = "Overwrite output file")
      flag("-v", "--verbose", help = "Show external commands")

      run:
        let raw = RawRebuildOptions(
          base: opts.base_opt,
          dev: opts.dev_opt,
          output: opts.output_opt,
          version: opts.version_opt,
          rootfsMode: opts.rootfs_mode_opt,
          compression: some(opts.compression),
          blockSize: some(opts.block_size),
          exclude: opts.exclude,
          force: opts.force,
          verbose: opts.verbose,
          keepWorkdir: opts.keep_workdir
        )

        let rebuildResult = runRebuild(raw)
        if rebuildResult.isErr:
          let e = rebuildResult.error()
          stderr.writeLine(e.displayMessage())
          status = e.exitCode()

  try:
    parser.run()
  except ShortCircuit as err:
    if err.flag == "argparse_help":
      stdout.writeLine(err.help)
      return 0

    stderr.writeLine(&"unexpected short-circuit option: {err.flag}")
    return 1
  except UsageError:
    stderr.writeLine(getCurrentExceptionMsg())
    return 1

  return status
