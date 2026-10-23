# PLAN log

Completed PLAN.md items retired by plan-retire, oldest retirement first.

## Retired 2026-10-14

- [x] [Done (recent)] Repair repo state: HEAD re-pointed from `refs/jj/root` to `yolo`, index rebuilt (done 2026-10-06 17:36 EDT)
- [x] [Done (recent)] Provisional INTENT.md (done 2026-10-06 17:37 EDT)
- [x] [Done (recent)] Coarse-clock test: injected 1 ms / 100 ns / 1 ns clocks with backward steps; strict monotonicity + uniqueness (done 2026-10-06 17:39 EDT, aff3ac0)
- [x] [Done (recent)] LuaJIT on Windows: FILETIME clock, BCryptGenRandom, LockFileEx counter; daemon refused (done 2026-10-06 17:45 EDT, 178d750)
- [x] [Done (recent)] Real runs of ./test on Windows 10 x86_64 and macOS 26.7.1 arm64 (done 2026-10-06 17:46 EDT, 178d750)
- [x] [Done (recent)] Fix oracle: extract-ns wrapped modulo 2^64; explicit timestamps outside [0, INT64_MAX] refused in CLI + daemon (done 2026-10-06 17:49 EDT, 4de3e2f)
- [x] [Done (recent)] Zig port: pure core, pointer+length C ABI, C CLI, ./build, ./build-all for 5 triples + wasm32 (done 2026-10-06 18:06 EDT, 2bbd864)
- [x] [Done (recent)] LuaJIT-oracle differential suites (C ABI and CLI), 8 mutants caught (done 2026-10-06 18:06 EDT, 2bbd864)

## Retired 2026-10-15

- [x] [Done (recent)] Mechatron Prime CI targets manifest + badge; README platform table (done 2026-10-06 18:10 EDT, 39bb636)
- [x] [Done (recent)] wasm32-freestanding core compiles with all exports; ReleaseSmall 7,047 bytes (done 2026-10-06 18:10 EDT)

## Retired 2026-10-21

- [x] [Done (recent)] BDFN chose to fix the inherited CLI argument quirks (done 2026-10-06 23:08 EDT)
- [x] [Done (recent)] Both CLIs: order-independent flags, last timestamp wins, unknown/extra arguments error, -- ends options, extract takes one UUID (done 2026-10-06 23:13 EDT, bede2d2)

## Retired 2026-10-23

- [x] [Next (authorized, unblocked)] Reproducible Windows test toolchain: flake output luajit-windows-x86_64 + import check, and ./test-windows runner (done 2026-10-14 14:32 EDT)
- [x] [Next (authorized, unblocked)] Fix: Linux LuaJIT CLI's SysV shared-memory counter is unlocked (16 processes x 60 at one ns: 5-10 duplicates in 960); use the flock'd counter file as on macOS (done 2026-10-14 17:20 EDT, 7152467)
- [x] [Next (authorized, unblocked)] Windows daemon (BDFN chose C2, 2026-10-14): Winsock AF_UNIX + WSAPoll, handoff restart; daemon suites run on Windows (context: docs/plan_context/windows_daemon.md) (done 2026-10-14 17:55 EDT, cc2bd0f)
