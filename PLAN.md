# PLAN

Open work in priority order. Completed items: [docs/PLAN_LOG.md](docs/PLAN_LOG.md). Direction and done criteria: [intents/three_os_and_zig_port.md](intents/three_os_and_zig_port.md).

## Next (authorized, unblocked)
- [ ] Counter/daemon scope audit (Turing request 2026-10-14): state file and socket are found via TMPDIR/XDG_RUNTIME_DIR, so sharing is per matching environment; add deterministic regressions for differing TMPDIR, daemon/standalone transitions and unsafe shared /tmp, then fix within per-user scope (context: docs/plan_context/counter_scope.md)
	- [ ] Daemon clients refuse a socket owned by another user (SO_PEERCRED / getpeereid)
	- [ ] Squatting: another local user can pre-create /tmp/uuidv7-<uid>, which now makes the CLIs fail closed; BDFN idea (2026-10-28): an unguessable /tmp/uuidv7-<uid>-<uuidv7> remembered in a user-only place; design to be agreed
	- [x] Daemon persistence: write the per-user state file on every allocation (RAM) and seed from it at start; measure the cost (phase 1, context: docs/plan_context/system_service.md) (done 2026-10-21 15:05 EDT)
- [ ] System service, layered default (BDFN 2026-10-19): plan approved 2026-10-21 (context: docs/plan_context/system_service.md)
	- [x] Phase 2: client discovery order, system-socket trust check and refused-service policy (exit 75 x3, then 1) in uuidv7 and uuidv7z (done 2026-10-23 14:40 EDT)
	- [x] Phase 3: systemd socket activation, unit files, NixOS module and NixOS VM test; `--daemon --service` refuses control commands (+++, r, l) while the per-user daemon keeps them (done 2026-10-23 23:50 EDT)
	- [ ] Phase 3 on a real Linux host: enable the units and rerun the VM test's checks there (install needs approval)
	- [x] An unusable state directory is never silent (BDFN 2026-10-28): the daemon and both CLIs warn on stderr, the daemon logs it and warns at start, the VM test checks the service journal has no such warning (done 2026-10-28 09:45 EDT)
	- [x] Found by that warning: on macOS, openat(O_CREAT) of a new counter file sometimes fails with ENOENT while concurrent processes create it (Lua 3 of 160 rounds of 24 first calls, uuidv7z 2 of 700), so the process silently used its own counter; both CLIs now retry ENOENT (0 of 300 and 0 of 1200 after); tests/uuidv7_concurrency_test fails on any state warning (done 2026-10-28 09:40 EDT)
	- [x] Fail closed (BDFN 2026-10-28: no UUID without the ordering guarantee): a daemon that cannot use its state file refuses to start, a running one answers ERR, both CLIs exit 1; the VM test checks a misconfigured service hands out no UUIDs (done 2026-10-28 10:30 EDT)
	- [ ] Phase 4: launchd socket activation and plist (real-host sudo needs approval)
	- [ ] Phase 5: Windows service host (install on the test host needs approval)
	- [x] Decided: refused system socket -> service restarted up to N times with a try-again message, then an error; macOS state in /private/tmp by default, configurable (done 2026-10-21 14:46 EDT)
	- [x] Decided: the service manager restarts a crashed system service (systemd Restart=always + StartLimitBurst=N, launchd KeepAlive, SCM recovery actions) (done 2026-10-23 01:00 EDT)
	- [x] Decided: N = 3 restarts before a refused system socket is an error (done 2026-10-23 14:15 EDT)

- [ ] Conform to the cross-platform build convention: PF-named bin/<PF>/ and zig-out/<PF>/[musl]/<profile>/, mswin token, ./run, --all-plats (BDFN 2026-10-23; context: docs/plan_context/build_layout.md)

## Awaiting BDFN decisions (queued in the walking brief)
- [ ] Decision uuidv7-os-rng-failure-policy revision 2 (queued 2026-10-14): fail closed or keep the warn + clock-seeded fallback when the OS RNG fails

## Investigate
- [x] macOS: the daemon suites printed `sh: line 1: N Killed: 9 env ...` when cleanup hard-killed a popen'd daemon; daemons now start with exec (done 2026-10-28 10:30 EDT)
- [ ] macOS: 24 concurrent `bin/uuidv7` launches via the `#!/usr/bin/env luajit` shebang fail with ENOMEM / SIGKILL at exec on one Mac under swap pressure (85% used); `luajit bin/uuidv7` never fails; cause unproven (2026-10-14)

## Blocked on hardware
- [ ] Windows aarch64 runtime verification (needs a reachable ARM64 Windows host; compile + header check only so far)
- [ ] Linux aarch64 on real hardware (QEMU user-mode: Zig unit tests + uuidv7z CLI differential pass, 2026-10-06 18:10 EDT); LuaJIT side not run there

## Conditional
- [ ] If uuidv7z gains batch output or a many-UUIDs-per-process library API: seed randomz's BLAKE3 DRBG once from OS entropy instead of a syscall per new tick (sibling-Zig import; mind fork duplication)

## Done (recent)
