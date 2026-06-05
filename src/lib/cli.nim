# Command line interface for lxcpkg.

import std/options
import std/strformat

import argparse
import results

import build
import delta
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
