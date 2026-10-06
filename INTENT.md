# uuidv7 intent

Status: provisional. Drafted from the README and the 2026-10-06 kickoff request;
the open questions below still need answers from the BDFN (Benevolent Dictator For Now).

## Purpose and users

A small, fast generator of RFC 9562 UUIDv7 values for people and services that
need time-ordered identifiers (database keys, record and audit IDs). It runs as a
CLI, an optional local daemon and, once the Zig port lands, as a library with a
C ABI that other programs can embed.

## Desired outcomes

- Every value is a valid RFC 9562 version 7 UUID (version and variant bits set).
- Values from one machine are strictly increasing and unique, including when the
  clock is coarse (1 ms or 100 ns resolution) or steps backward.
- The encoded timestamp is recoverable (`--extract-timestamp-ms/-ns`), with
  nanosecond precision for values this tool produced.
- The tool and its test suite work on Linux, macOS and Windows.
- A Zig implementation (pure core, C FFI, C CLI) produces byte-identical output
  to the LuaJIT implementation for identical inputs, with the LuaJIT version
  acting as the independent oracle in differential tests.

## Scope and non-goals

- In scope: generation, ordering guarantees, timestamp extraction, the CLI,
  the LuaJIT daemon on Unix, and cross-compiled Zig builds for macOS aarch64,
  Linux aarch64/x86_64 and Windows aarch64/x86_64.
- Not in scope without a separate decision: package publishing, GitHub
  releases, a wasm32 integration for JavaScript consumers (feasibility note only).

## Constraints

- Only LuaJIT is required at runtime for the LuaJIT implementation.
- Cryptographically secure randomness wherever the OS offers it; any insecure
  fallback must warn loudly.
- Default LuaJIT behavior must not change when adding test seams.

## How success is verified

- `./test` runs every suite and fails if any fails.
- Per-OS verification is reported by method: a real run, CI, emulation, or only
  cross-compilation. A build alone never counts as "works".
- Differential tests compare the Zig and LuaJIT implementations; checks the Zig
  side did not author (round-trip, RFC 9562 bit layout, sorted-sweep ordering)
  are preferred.

## Open questions

- Windows daemon: unsupported (explicit refusal) or ported (AF_UNIX via Winsock,
  or a named pipe)?
- Should the Zig CLI share the LuaJIT CLI's cross-process counter state and
  honor a running LuaJIT daemon, so mixing the two on one machine stays monotonic?

See [PLAN.md](PLAN.md) for current work.
- Direction and done criteria: [intents/three_os_and_zig_port.md](intents/three_os_and_zig_port.md)
