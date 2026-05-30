# Result and error definitions for lxcpkg.
#
# Internal modules should return LxResult[T] instead of raising exceptions
# for expected failures. The CLI layer is responsible for formatting errors
# and mapping them to process exit codes.

import std/strformat
import results

type
  ErrorKind* = enum
    ekInvalidArgument
    ekMissingArgument
    ekInvalidRootfs
    ekUnsupportedArch
    ekArchMismatch
    ekInvalidDataMount
    ekAccountNotFound
    ekInvalidManifest
    ekExternalToolMissing
    ekExternalCommandFailed
    ekOutputExists
    ekIoError
    ekInternalError

  LxError* = object
    kind*: ErrorKind
    message*: string
    detail*: string

  LxResult*[T] = Result[T, LxError]

proc newError*(kind: ErrorKind; message: string; detail = ""): LxError =
  result = LxError(kind: kind, message: message, detail: detail)

proc displayMessage*(e: LxError): string =
  if e.detail.len == 0:
    result = e.message
  else:
    result = &"{e.message}: {e.detail}"

proc exitCode*(e: LxError): int =
  ## Keep the first version simple: expected user/configuration errors return
  ## 1, and unexpected internal errors return 2.
  case e.kind
  of ekInternalError:
    result = 2
  else:
    result = 1

proc invalidArgument*(message: string; detail = ""): LxError =
  result = newError(ekInvalidArgument, message, detail)

proc missingArgument*(name: string): LxError =
  result = newError(ekMissingArgument, &"missing required argument: {name}")

proc invalidRootfs*(message: string; detail = ""): LxError =
  result = newError(ekInvalidRootfs, message, detail)

proc unsupportedArch*(message: string; detail = ""): LxError =
  result = newError(ekUnsupportedArch, message, detail)

proc archMismatch*(specified, detected: string): LxError =
  result = newError(
    ekArchMismatch,
    "specified architecture does not match rootfs architecture",
    &"specified={specified}, detected={detected}"
  )

proc invalidDataMount*(message: string; detail = ""): LxError =
  result = newError(ekInvalidDataMount, message, detail)

proc accountNotFound*(kind, name: string): LxError =
  result = newError(ekAccountNotFound, &"{kind} not found in rootfs accounts", name)

proc externalToolMissing*(tool: string): LxError =
  result = newError(ekExternalToolMissing, &"required external tool not found: {tool}")

proc externalCommandFailed*(command: string; exitCode: int; detail = ""): LxError =
  result = newError(
    ekExternalCommandFailed,
    &"external command failed: {command}",
    &"exitCode={exitCode}" & (if detail.len == 0: "" else: &", {detail}")
  )

proc outputExists*(path: string): LxError =
  result = newError(ekOutputExists, "output file already exists", path)

proc ioError*(message: string; detail = ""): LxError =
  result = newError(ekIoError, message, detail)

proc internalError*(message: string; detail = ""): LxError =
  result = newError(ekInternalError, message, detail)
