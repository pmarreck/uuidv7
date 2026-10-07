# PLAN

Kickoff 2026-10-06: three-OS support, coarse-clock proof, Zig port with LuaJIT as oracle.

- [x] Repair repo state: HEAD re-pointed from `refs/jj/root` to `yolo`, index rebuilt (2026-10-06 17:36 EDT)
- [x] Provisional INTENT.md (2026-10-06 17:37 EDT)
- [x] Ack the kickoff note; email open questions (Windows daemon, Zig/LuaJIT shared counter) (2026-10-06 17:38 EDT)
- [x] Coarse-clock test: injected clock at 1 ms and 100 ns resolution plus backward steps; strict monotonicity + uniqueness (2026-10-06 17:39 EDT)
- [x] LuaJIT injection seam: pure `advance` takes the counter-init random value; pure byte encoder from (ns, counter) (2026-10-06 17:39 EDT)
- [x] LuaJIT on Windows: GetSystemTimePreciseAsFileTime clock, BCryptGenRandom RNG, LockFileEx counter file in %TEMP% (2026-10-06 17:45 EDT)
- [x] Windows test run on a real Windows host (LuaJIT + Git Bash); report method: Windows 10 x86_64 via SSH + Git Bash, static mingw LuaJIT (2026-10-06 17:45 EDT)
- [x] macOS test run on a real Mac: macOS 26.7.1 arm64 via SSH (2026-10-06 17:46 EDT)
- [x] Zig core (pure, no I/O): advance, encode, format, parse, extract (2026-10-06 18:06 EDT)
- [x] C FFI with pointer+length buffers; header (2026-10-06 18:06 EDT)
- [x] C CLI over the FFI: clock, RNG, counter state, flags matching LuaJIT CLI (2026-10-06 18:06 EDT)
- [x] `./build` with cross-compilation for the 5 target triples (2026-10-06 18:06 EDT)
- [x] Differential suite (LuaJIT oracle via FFI load of the Zig library): encode bytes, extract edges + large sample, sorted sweep (2026-10-06 18:06 EDT)
- [x] CLI differential: hyphen/compact/case, refusals, exit codes (2026-10-06 18:06 EDT)
- [x] Mechatron Prime CI targets manifest + badge: first build PASS on 39bb636, badge PASSING (2026-10-06 18:10 EDT)
- [x] README: platforms, verification methods, Zig CLI (2026-10-06 18:09 EDT)
- [x] wasm32-freestanding: the core compiles (checked by ./build-all); exports not exercised by any host yet (2026-10-06 18:06 EDT)
- [ ] Reproducible Windows test toolchain: flake output for a static mingw LuaJIT (currently built ad hoc with an override)
- [ ] Windows aarch64 verification (no ARM64 Windows host known; ask)
- [x] Fix oracle: --extract-timestamp-ns wrapped modulo 2^64; explicit timestamps outside [0, INT64_MAX] now refused (CLI + daemon) (2026-10-06 17:49 EDT)
- [x] BDFN chose to fix the inherited CLI quirks (`uuidv7 - foo` ignores `foo`; `uuidv7 123 --hyphen` ignores `--hyphen`; `uuidv7 123 456` uses 123) (2026-10-06 23:08 EDT)
- [ ] Linux aarch64 on real hardware (QEMU user-mode: Zig unit tests + uuidv7z CLI differential pass, 2026-10-06 18:10 EDT); LuaJIT side not run there
- [ ] Decide (BDFN): refuse to generate when the OS RNG fails (randomz policy) instead of the warn + insecure-fallback path, in both implementations
- [ ] If uuidv7z gains batch output or a many-UUIDs-per-process library API: seed randomz's BLAKE3 DRBG once from OS entropy instead of a syscall per new tick (sibling-Zig import; mind fork duplication)
- [x] Fixed inherited CLI argument quirks in both CLIs: order-independent flags, later timestamp wins, unknown/extra arguments error; -- ends options; extract takes one UUID (2026-10-06 23:13 EDT)
