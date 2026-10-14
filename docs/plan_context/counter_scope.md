# Counter and daemon scope (audit, 2026-10-14)

Question: is ordering really machine-wide, or only shared by processes whose
environment happens to match?

## How the state is found today

| Thing | Lookup |
|---|---|
| Counter state file (both CLIs) | `$TMPDIR/uuidv7-sequence`, else `/tmp/uuidv7-sequence` (Windows: `TMPDIR`, `TEMP`, `TMP`) |
| Daemon socket (both clients, daemon) | `$UUIDV7_SOCK`, else `uuidv7.sock` in `XDG_RUNTIME_DIR`, `TMPDIR`, (Windows) `TEMP`/`TMP`, else `/tmp` |

The two lookups differ, and both depend on environment variables.

## Measured boundaries

- Two processes of the same user with different `TMPDIR` keep separate counters.
  Alternating them at one static nanosecond: 20 of 40 values out of order.
- `TMPDIR` is not stable for one user: `nix develop` sets a per-shell
  `/tmp/nix-shell.XXXXXX`; a clean environment (cron, services) has none and uses
  `/tmp`; login shells may set their own.
- An unusable state file (for example read-only, or owned by another user in a
  shared `/tmp`) silently falls back to per-process state: ordering broke with no
  warning.
- A symlink at the state path was followed and its target overwritten or created.
  Fixed in 7746c5a (`O_NOFOLLOW`), covered by `tests/uuidv7_state_safety_test`.
- The daemon clients do not check who owns the socket they connect to. With the
  socket in a shared directory (`/tmp` when `XDG_RUNTIME_DIR` and `TMPDIR` are
  unset), another user could listen there first and choose the values a victim's
  CLI prints. Not yet fixed.
- Daemon/standalone transitions: the daemon keeps its counter in memory and never
  reads or writes the state file. While the wall clock moves forward this is
  harmless, because a later call reads a later clock. If the clock steps back
  while the daemon runs, the daemon freezes time ahead of the clock, and after it
  stops a standalone call can emit a smaller value. The reverse also holds for a
  daemon started after a clock step back.

## What holds without shared state

- Calls that do not overlap in real time are ordered by the clock alone, as long
  as the wall clock does not step back between them. Separate process launches
  are milliseconds apart, far above the clock resolution (1 ns on Linux and macOS,
  100 ns on Windows).
- Overlapping calls, calls in one clock tick, and calls across a clock step back
  need the shared, locked state. Without it, uniqueness is only probabilistic
  (the 53-bit random counter seed) and ordering is not guaranteed.

## Scope by boundary (today)

| Boundary | Shared state? |
|---|---|
| Same user, same `TMPDIR` | yes |
| Same user, different `TMPDIR` (dev shell vs plain shell vs cron) | no |
| Different users | no; with a shared `/tmp`, the first user's file blocks the others, who silently fall back |
| Across reboot | no: `/tmp` is usually cleared; ordering then relies on the clock |

## Proposed fix (awaiting BDFN decision)

Per-user scope that does not depend on the environment:

- State directory from the OS account, not environment variables: on Linux and
  macOS `<home from getpwuid(geteuid())>/.local/state/uuidv7/` (mode 0700); on
  Windows the Local AppData known folder plus `\uuidv7\`. The counter file and the
  daemon socket both live there.
- `UUIDV7_STATE_DIR` as an explicit override for tests and deliberate isolation.
- Persistent storage, so the counter survives a reboot and a clock that is behind
  after boot cannot reorder values.
- The daemon seeds its counter from the state file at start and writes its last
  state back on stop and before a restart.
- Clients refuse a daemon whose peer is a different user (`SO_PEERCRED` on Linux,
  `getpeereid` on macOS).
- An unusable state file: fail closed (exit 1) or warn and fall back to
  per-process state. This is the same choice as the RNG-failure policy.

Machine-wide across users needs a system service that owns the state (a
systemd, launchd or Windows service with a group-restricted socket). It needs
installation privileges and is not proposed for now. World-writable shared files
are not an option.

Known caveat of a home-based location: a home directory shared between machines
over NFS would share the counter file across them (relying on NFS locking), and
two machines' daemons would contend for one socket path.
