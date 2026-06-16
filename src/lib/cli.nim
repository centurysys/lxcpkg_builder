# Command line interface for lxcpkg.

import std/options
import std/strformat

import argparse
import results

import build
import build_tarball
import delta
import download_build
import errors
import rebuild
import rewrite_metadata

proc runCli*(): int =
  var status = 0

  var parser = newParser("lxcpkg"):
    help("Build LXC application packages for MAX3xx WebUI")

    command("build"):
      help("Build a .lxcpkg archive from a rootfs directory")

      option("-r", "--rootfs", help = "Source rootfs directory")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("-P", "--package-id", help = "Package ID, for example com.example.app")
      option("-n", "--name", help = "Package name")
      option("-V", "--version", help = "Package version")
      option("-a", "--arch", choices = @["armhf", "aarch64"], help = "Target architecture")
      option("-m", "--rootfs-mode", choices = @["persistent", "volatile", "snapshot"], help = "Initial rootfs overlay mode")
      option("-c", "--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("-B", "--block-size", default = some("1M"), help = "Squashfs block size")
      option("-D", "--data", multiple = true, help = "Data mount: name:target[:uid-or-user[:gid-or-group[:mode]]]")
      option("-e", "--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      option("-p", "--preset", default = some("none"), choices = @["none", "auto-appliance", "alpine-appliance", "debian-appliance", "ubuntu-appliance"], help = "Product rootfs profile preset")
      option("-N", "--normalize", default = some("none"), choices = @["none", "product"], help = "Rootfs normalize profile")
      option("-M", "--minimize", default = some("none"), choices = @["none", "auto", "alpine", "debian"], help = "Rootfs minimize profile")
      option("--network-mode", default = some("dhcp"), choices = @["dhcp", "host-configured"], help = "Rootfs network startup mode")
      flag("--non-interactive", help = "Do not prompt for missing values")
      flag("--no-ensure-ssh-host-keys", help = "Do not add a systemd ssh.service drop-in that regenerates missing OpenSSH host keys")
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
          normalize: some(opts.normalize),
          minimize: some(opts.minimize),
          networkMode: some(opts.network_mode),
          preset: some(opts.preset),
          nonInteractive: opts.non_interactive,
          ensureSshHostKeys: not opts.no_ensure_ssh_host_keys,
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

      option("-L", "--lxc-dir", help = "LXC container directory containing config and rootfs")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("-P", "--package-id", help = "Package ID, for example com.example.app")
      option("-n", "--name", help = "Package name")
      option("-V", "--version", help = "Package version")
      option("-a", "--arch", choices = @["armhf", "aarch64"], help = "Target architecture")
      option("-m", "--rootfs-mode", choices = @["persistent", "volatile", "snapshot"], help = "Initial rootfs overlay mode")
      option("-c", "--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("-B", "--block-size", default = some("1M"), help = "Squashfs block size")
      option("-D", "--data", multiple = true, help = "Data mount: name:target[:uid-or-user[:gid-or-group[:mode]]]")
      option("-e", "--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      option("-N", "--normalize", default = some("none"), choices = @["none", "product"], help = "Rootfs normalize profile")
      option("-M", "--minimize", default = some("none"), choices = @["none", "auto", "alpine", "debian"], help = "Rootfs minimize profile")
      option("--network-mode", default = some("dhcp"), choices = @["dhcp", "host-configured"], help = "Rootfs network startup mode")
      option("-p", "--preset", default = some("none"), choices = @["none", "auto-appliance", "alpine-appliance", "debian-appliance", "ubuntu-appliance"], help = "Product rootfs profile preset")
      flag("--no-ensure-ssh-host-keys", help = "Do not add a systemd ssh.service drop-in that regenerates missing OpenSSH host keys")
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
          preset: some(opts.preset),
          ensureSshHostKeys: not opts.no_ensure_ssh_host_keys,
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

      option("-d", "--dist", help = "Distribution name, for example alpine, debian, ubuntu, fedora")
      option("-R", "--release", help = "Distribution release, for example 3.23, trixie, noble, 44")
      option("-a", "--arch", choices = @["armhf", "arm64", "aarch64", "armv7", "armv7l"], help = "Target architecture")
      option("-b", "--bits", choices = @["32", "64"], help = "Target ARM width; 64 maps to arm64, 32 maps to armhf")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("-P", "--package-id", help = "Package ID, for example com.example.app")
      option("-n", "--name", help = "Package name")
      option("-V", "--version", help = "Package version")
      option("-m", "--rootfs-mode", choices = @["persistent", "volatile", "snapshot"], help = "Initial rootfs overlay mode")
      option("-c", "--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("-B", "--block-size", default = some("1M"), help = "Squashfs block size")
      option("-D", "--data", multiple = true, help = "Data mount: name:target[:uid-or-user[:gid-or-group[:mode]]]")
      option("-e", "--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      option("--normalize", default = some("product"), choices = @["none", "product"], help = "Rootfs normalize profile")
      option("--minimize", default = some("auto"), choices = @["none", "auto", "alpine", "debian"], help = "Rootfs minimize profile")
      option("--network-mode", default = some("dhcp"), choices = @["dhcp", "host-configured"], help = "Rootfs network startup mode")
      option("-p", "--preset", default = some("none"), choices = @["none", "auto-appliance", "alpine-appliance", "debian-appliance", "ubuntu-appliance"], help = "Product rootfs profile preset")
      option("-w", "--work-dir", help = "Parent directory for temporary download work directory; default is /var/tmp")
      flag("--interactive", help = "Let lxc-download ask for missing distribution/release information")
      flag("--no-ensure-ssh-host-keys", help = "Do not add a systemd ssh.service drop-in that regenerates missing OpenSSH host keys")
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
          preset: some(opts.preset),
          interactive: opts.interactive,
          workDir: opts.work_dir_opt,
          ensureSshHostKeys: not opts.no_ensure_ssh_host_keys,
          keepWorkdir: opts.keep_workdir,
          force: opts.force,
          verbose: opts.verbose
        )

        let downloadResult = runBuildDownload(raw)
        if downloadResult.isErr:
          let e = downloadResult.error()
          stderr.writeLine(e.displayMessage())
          status = e.exitCode()


    command("build-tarball"):
      help("Extract a rootfs tarball and build a .lxcpkg archive")

      option("-t", "--tarball", help = "Rootfs tarball, for example rootfs.tar.xz, rootfs.tar.zst, or rootfs.tar.gz")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("-P", "--package-id", help = "Package ID, for example com.example.app")
      option("-n", "--name", help = "Package name")
      option("-V", "--version", help = "Package version")
      option("-a", "--arch", choices = @["armhf", "aarch64"], help = "Target architecture")
      option("-m", "--rootfs-mode", choices = @["persistent", "volatile", "snapshot"], help = "Initial rootfs overlay mode")
      option("-c", "--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("-B", "--block-size", default = some("1M"), help = "Squashfs block size")
      option("-D", "--data", multiple = true, help = "Data mount: name:target[:uid-or-user[:gid-or-group[:mode]]]")
      option("-e", "--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      option("--normalize", default = some("product"), choices = @["none", "product"], help = "Rootfs normalize profile")
      option("--minimize", default = some("auto"), choices = @["none", "auto", "alpine", "debian"], help = "Rootfs minimize profile")
      option("--network-mode", default = some("dhcp"), choices = @["dhcp", "host-configured"], help = "Rootfs network startup mode")
      option("-p", "--preset", default = some("none"), choices = @["none", "auto-appliance", "alpine-appliance", "debian-appliance", "ubuntu-appliance"], help = "Product rootfs profile preset")
      option("-w", "--work-dir", help = "Parent directory for temporary extraction work directory; default is /var/tmp")
      flag("--no-ensure-ssh-host-keys", help = "Do not add a systemd ssh.service drop-in that regenerates missing OpenSSH host keys")
      flag("--keep-workdir", help = "Keep temporary extraction/build directory after successful build")
      flag("-f", "--force", help = "Overwrite output file")
      flag("-v", "--verbose", help = "Show external commands")

      run:
        let raw = RawBuildTarballOptions(
          tarball: opts.tarball_opt,
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
          preset: some(opts.preset),
          workDir: opts.work_dir_opt,
          ensureSshHostKeys: not opts.no_ensure_ssh_host_keys,
          keepWorkdir: opts.keep_workdir,
          force: opts.force,
          verbose: opts.verbose
        )

        let tarballResult = runBuildTarball(raw)
        if tarballResult.isErr:
          let e = tarballResult.error()
          stderr.writeLine(e.displayMessage())
          status = e.exitCode()


    command("delta"):
      help("Build a .lxcdelta archive from a base package and a .lxcdev archive")

      option("-b", "--base", help = "Base .lxcpkg file")
      option("-d", "--dev", help = "Development .lxcdev archive")
      option("-o", "--output", help = "Output .lxcdelta file")
      option("-V", "--version", help = "Package version for delta package")
      option("-c", "--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("-B", "--block-size", default = some("1M"), help = "Squashfs block size")
      option("-e", "--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
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

      option("-b", "--base", help = "Base .lxcpkg file")
      option("-d", "--dev", help = "Development .lxcdev archive")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("-V", "--version", help = "Package version for rebuilt package")
      option("-m", "--rootfs-mode", choices = @["persistent", "volatile", "snapshot"], help = "Rootfs overlay mode for rebuilt package")
      option("-c", "--compression", default = some("zstd"), choices = @["zstd", "xz", "gzip", "lz4", "lzo"], help = "Squashfs compression")
      option("-B", "--block-size", default = some("1M"), help = "Squashfs block size")
      option("-e", "--exclude", multiple = true, help = "Additional mksquashfs exclude pattern")
      flag("--no-clean", help = "Do not remove apt/cache/log/tmp files from the merged rootfs before creating rootfs.sqfs")
      flag("--no-scrub", help = "Do not remove machine-id, SSH host keys, shell history, and other instance-specific files before creating rootfs.sqfs")
      flag("--no-prune-empty-dirs", help = "Do not remove empty cleanup directories after release cleanup")
      flag("--no-release-clean", help = "Disable the default release cleanup; equivalent to --no-clean --no-scrub --no-prune-empty-dirs")
      flag("--no-ensure-ssh-host-keys", help = "Do not add a systemd ssh.service drop-in that regenerates missing OpenSSH host keys")
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
          clean: not opts.no_clean and not opts.no_release_clean,
          scrub: not opts.no_scrub and not opts.no_release_clean,
          pruneEmptyDirs: not opts.no_prune_empty_dirs and not opts.no_release_clean,
          ensureSshHostKeys: not opts.no_ensure_ssh_host_keys,
          force: opts.force,
          verbose: opts.verbose,
          keepWorkdir: opts.keep_workdir
        )

        let rebuildResult = runRebuild(raw)
        if rebuildResult.isErr:
          let e = rebuildResult.error()
          stderr.writeLine(e.displayMessage())
          status = e.exitCode()


    command("rewrite-metadata"):
      help("Rewrite manifest metadata in an existing .lxcpkg archive without rebuilding rootfs.sqfs")

      option("-i", "--input", help = "Input .lxcpkg file")
      option("-o", "--output", help = "Output .lxcpkg file")
      option("-P", "--package-id", help = "New package ID")
      option("-n", "--name", help = "New package name")
      option("-V", "--version", help = "New package version")
      flag("--keep-workdir", help = "Keep temporary rewrite-metadata directory after successful rewrite")
      flag("-f", "--force", help = "Overwrite output file")
      flag("-v", "--verbose", help = "Show external commands")

      run:
        let raw = RawRewriteMetadataOptions(
          input: opts.input_opt,
          output: opts.output_opt,
          packageId: opts.package_id_opt,
          name: opts.name_opt,
          version: opts.version_opt,
          force: opts.force,
          verbose: opts.verbose,
          keepWorkdir: opts.keep_workdir
        )

        let rewriteResult = runRewriteMetadata(raw)
        if rewriteResult.isErr:
          let e = rewriteResult.error()
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
