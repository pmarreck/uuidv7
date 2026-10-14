# PLAN

Open work in priority order. Completed items: [docs/PLAN_LOG.md](docs/PLAN_LOG.md). Direction and done criteria: [intents/three_os_and_zig_port.md](intents/three_os_and_zig_port.md).

## Next (authorized, unblocked)
- [x] Fix: Linux LuaJIT CLI's SysV shared-memory counter is unlocked (16 processes x 60 at one ns: 5-10 duplicates in 960); use the flock'd counter file as on macOS (done 2026-10-14 17:20 EDT, 7152467)
- [ ] Windows daemon (BDFN chose C2, 2026-10-14): Winsock AF_UNIX + WSAPoll, handoff restart; daemon suites run on Windows (context: docs/plan_context/windows_daemon.md)
- [ ] Shared machine-wide counter (BDFN goal 2026-10-14: monotonicity across the whole machine): uuidv7 and uuidv7z share one locked state file, and uuidv7z uses a running daemon
- [x] Reproducible Windows test toolchain: flake output luajit-windows-x86_64 + import check, and ./test-windows runner (done 2026-10-14 14:32 EDT)

## Awaiting BDFN decisions (queued in the walking brief)
- [ ] Decision uuidv7-os-rng-failure-policy revision 2 (queued 2026-10-14): fail closed or keep the warn + clock-seeded fallback when the OS RNG fails

## Investigate
- [ ] macOS: 24 concurrent `bin/uuidv7` launches via the `#!/usr/bin/env luajit` shebang fail with ENOMEM / SIGKILL at exec on one Mac under swap pressure (85% used); `luajit bin/uuidv7` never fails; cause unproven (2026-10-14)

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
