# PLAN

Kickoff 2026-10-06: three-OS support, coarse-clock proof, Zig port with LuaJIT as oracle.

- [x] Repair repo state: HEAD re-pointed from `refs/jj/root` to `yolo`, index rebuilt (2026-10-06 17:45 EDT)
- [x] Provisional INTENT.md (2026-10-06 17:50 EDT)
- [x] Ack the kickoff note; email open questions (Windows daemon, Zig/LuaJIT shared counter) (2026-10-06 17:58 EDT)
- [x] Coarse-clock test: injected clock at 1 ms and 100 ns resolution plus backward steps; strict monotonicity + uniqueness (2026-10-06 18:15 EDT)
- [x] LuaJIT injection seam: pure `advance` takes the counter-init random value; pure byte encoder from (ns, counter) (2026-10-06 18:15 EDT)
- [ ] LuaJIT on Windows: GetSystemTimePreciseAsFileTime clock, BCryptGenRandom RNG, LockFileEx counter file in %TEMP%
- [ ] Windows test run on a real Windows host (LuaJIT + Git Bash); report method
- [ ] macOS test run on a real Mac; report method
- [ ] Zig core (pure, no I/O): advance, encode, format, parse, extract
- [ ] C FFI with pointer+length buffers; header
- [ ] C CLI over the FFI: clock, RNG, counter state, flags matching LuaJIT CLI
- [ ] `./build` with cross-compilation for the 5 target triples
- [ ] Differential suite (LuaJIT oracle via FFI load of the Zig library): encode bytes, extract edges + large sample, sorted sweep
- [ ] CLI differential: hyphen/compact/case, refusals, exit codes
- [ ] Mechatron Prime CI targets manifest + badge
- [ ] README: platforms, verification methods, Zig CLI
- [ ] Note wasm32-freestanding feasibility for the Zig core (no integration)
