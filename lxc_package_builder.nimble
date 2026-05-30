# Package

version       = "0.1.0"
author        = "Takeyoshi Kikuchi"
description   = "LXC package builder for MA series WebUI"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["lxcpkg"]


# Dependencies

requires "nim >= 2.2.10"
requires "argparse >= 4.0.2"
requires "results >= 0.5.1"
requires "checksums >= 0.2.2"
