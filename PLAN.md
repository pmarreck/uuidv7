# PLAN

Open work in priority order. Completed items: [docs/PLAN_LOG.md](docs/PLAN_LOG.md). Direction and done criteria: [intents/three_os_and_zig_port.md](intents/three_os_and_zig_port.md).

## Next (authorized, unblocked)
- [ ] Reproducible Windows test toolchain: flake output for the static mingw LuaJIT used by Windows runs (currently an ad hoc override)

## Awaiting BDFN decisions (queued in the walking brief)
- [ ] Decision uuidv7-os-rng-failure-policy: refuse to generate when the OS RNG fails, or keep the warn + insecure fallback (both implementations)
- [ ] Decision uuidv7-windows-daemon-scope: keep Windows local-only, or port the daemon
- [ ] Decision uuidv7-shared-counter-contract: share counter state between uuidv7 and uuidv7z, or keep separate streams

## Blocked on hardware
- [ ] Windows aarch64 runtime verification (needs a reachable ARM64 Windows host; compile + header check only so far)
- [ ] Linux aarch64 on real hardware (QEMU user-mode: Zig unit tests + uuidv7z CLI differential pass, 2026-10-06 18:10 EDT); LuaJIT side not run there

## Conditional
- [ ] If uuidv7z gains batch output or a many-UUIDs-per-process library API: seed randomz's BLAKE3 DRBG once from OS entropy instead of a syscall per new tick (sibling-Zig import; mind fork duplication)

## Done (recent)
- [x] Zig port: pure core, pointer+length C ABI, C CLI, ./build, ./build-all for 5 triples + wasm32 (done 2026-10-06 18:06 EDT, 2bbd864)
- [x] LuaJIT-oracle differential suites (C ABI and CLI), 8 mutants caught (done 2026-10-06 18:06 EDT, 2bbd864)
- [x] Mechatron Prime CI targets manifest + badge; README platform table (done 2026-10-06 18:10 EDT, 39bb636)
- [x] wasm32-freestanding core compiles with all exports; ReleaseSmall 7,047 bytes (done 2026-10-06 18:10 EDT)
- [x] BDFN chose to fix the inherited CLI argument quirks (done 2026-10-06 23:08 EDT)
- [x] Both CLIs: order-independent flags, last timestamp wins, unknown/extra arguments error, -- ends options, extract takes one UUID (done 2026-10-06 23:13 EDT, bede2d2)
