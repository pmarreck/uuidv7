# PLAN

Open work in priority order. Completed items: [docs/PLAN_LOG.md](docs/PLAN_LOG.md). Direction and done criteria: [intents/three_os_and_zig_port.md](intents/three_os_and_zig_port.md).

## Next (authorized, unblocked)
- [x] Fix: Linux LuaJIT CLI's SysV shared-memory counter is unlocked (16 processes x 60 at one ns: 5-10 duplicates in 960); use the flock'd counter file as on macOS (done 2026-10-14 17:20 EDT, 7152467)
- [x] Windows daemon (BDFN chose C2, 2026-10-14): Winsock AF_UNIX + WSAPoll, handoff restart; daemon suites run on Windows (context: docs/plan_context/windows_daemon.md) (done 2026-10-14 17:55 EDT, cc2bd0f)
- [x] Shared machine-wide counter (BDFN goal 2026-10-14: monotonicity across the whole machine): uuidv7 and uuidv7z share one locked state file, and uuidv7z uses a running daemon (done 2026-10-14 18:13 EDT)
	- [x] uuidv7z uses the shared `$TMPDIR/uuidv7-sequence` file; alternating and mixed-concurrent cross-CLI tests (done 2026-10-14 18:02 EDT)
	- [x] uuidv7z routes live generation to a running uuidv7 daemon (C client over AF_UNIX / Winsock; retry policy in the Zig core, 968a3e0) (done 2026-10-14 18:13 EDT)
- [x] Reproducible Windows test toolchain: flake output luajit-windows-x86_64 + import check, and ./test-windows runner (done 2026-10-14 14:32 EDT)
- [ ] Counter/daemon scope audit (Turing request 2026-10-14): state file and socket are found via TMPDIR/XDG_RUNTIME_DIR, so sharing is per matching environment; add deterministic regressions for differing TMPDIR, daemon/standalone transitions and unsafe shared /tmp, then fix within per-user scope (context: docs/plan_context/counter_scope.md)
	- [x] Measure the boundaries: differing TMPDIR 20/40 out of order, nix develop sets a per-shell TMPDIR, unusable file falls back silently, socket uses a different lookup (done 2026-10-14 19:25 EDT)
	- [x] Fix: state file written through a planted symlink (O_NOFOLLOW in both CLIs, tests/uuidv7_state_safety_test) (done 2026-10-14 19:21 EDT, 7746c5a)
	- [x] Per-user state directory from the OS account (home/.local/state/uuidv7, Local AppData on Windows), UUIDV7_STATE_DIR override; counter file and default socket both there (done 2026-10-15 13:00 EDT)
	- [ ] Daemon clients refuse a socket owned by another user (SO_PEERCRED / getpeereid)
	- [ ] Daemon state persistence covering crash/restart and concurrent file allocation: choose write-per-allocation vs durable reservation with BDFN
- [ ] Plan cross-user machine-wide ordering (BDFN: later): system service, or a one-time admin-created group-owned 0660 state file (idea from the sibling os_counters project); bring a plan first

## Awaiting BDFN decisions (queued in the walking brief)
- [x] Decision uuidv7-counter-scope: BDFN chose per user now, cross-user later (terminal answer, 2026-10-15 12:50 EDT)
- [ ] Decision uuidv7-os-rng-failure-policy revision 2 (queued 2026-10-14): fail closed or keep the warn + clock-seeded fallback when the OS RNG fails

## Investigate
- [ ] macOS: 24 concurrent `bin/uuidv7` launches via the `#!/usr/bin/env luajit` shebang fail with ENOMEM / SIGKILL at exec on one Mac under swap pressure (85% used); `luajit bin/uuidv7` never fails; cause unproven (2026-10-14)

## Blocked on hardware
- [ ] Windows aarch64 runtime verification (needs a reachable ARM64 Windows host; compile + header check only so far)
- [ ] Linux aarch64 on real hardware (QEMU user-mode: Zig unit tests + uuidv7z CLI differential pass, 2026-10-06 18:10 EDT); LuaJIT side not run there

## Conditional
- [ ] If uuidv7z gains batch output or a many-UUIDs-per-process library API: seed randomz's BLAKE3 DRBG once from OS entropy instead of a syscall per new tick (sibling-Zig import; mind fork duplication)

## Done (recent)
- [x] BDFN chose to fix the inherited CLI argument quirks (done 2026-10-06 23:08 EDT)
- [x] Both CLIs: order-independent flags, last timestamp wins, unknown/extra arguments error, -- ends options, extract takes one UUID (done 2026-10-06 23:13 EDT, bede2d2)
