# Direction: three operating systems and a Zig port with LuaJIT as oracle

Status: accepted (requested by the BDFN on 2026-10-06, relayed by a downstream
project that wants UUIDv7 record and audit IDs). Relation to root intent: delivers
the cross-platform and Zig outcomes in [INTENT.md](../INTENT.md).

## Done criteria

1. **Three platforms.** The tool and its test suite run on Linux, macOS and Windows.
   Report exactly how each OS was verified (real run, CI, emulation, or only
   cross-compilation). An OS whose build alone was checked is not "working".
2. **Coarse-clock test.** An injected-clock test proves strict monotonicity and
   uniqueness when the clock resolution is 1 ms and 100 ns, including a clock that
   steps backward.
3. **Zig implementation** following the fleet architecture: pure Zig core with no
   I/O, a C FFI with pointer+length buffers, a C CLI calling the core through that
   FFI, `./build`, and cross-compilation for macOS aarch64, Linux aarch64/x86_64
   and Windows aarch64/x86_64. Zig 0.16.
4. **LuaJIT as oracle.** Differential tests in `./test` where LuaJIT and Zig agree:
   - byte-identical output for the same explicit nanosecond timestamp and the same
     injected random/counter values;
   - `--extract-timestamp-ms/-ns` in both directions over a large sampled set, with
     exhaustive edges (0, max 48-bit ms, ms boundaries);
   - matching CLI behavior for hyphen/compact/case, refusals and exit codes.
   Any LuaJIT injection seam must leave its default behavior unchanged. Prefer
   checks the Zig side did not author (round-trip, RFC 9562 bit layout, ordering
   under a sorted sweep).
5. Mechatron Prime CI builds and tests the repo (targets manifest and badge), and
   the README documents the platforms and the Zig CLI.

## Optional (ask before spending much time)

Note whether the Zig core can target wasm32-freestanding cheaply, for a possible
JavaScript/Workers consumer. Do not build that integration.

## Boundaries

Failing test first; commit and push to `yolo` when green; no force pushes, history
rewrites, jj ref deletion, releases or package publishing without approval.
