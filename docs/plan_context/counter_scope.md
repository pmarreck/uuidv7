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
  warning. Since 2026-10-28 both CLIs exit 1 and the daemon refuses to start or answers ERR.
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

## Decision and status

BDFN chose per user now, cross-user later (2026-10-15). Done: the per-user state
directory below (both CLIs, daemon and clients; `tests/uuidv7_state_dir_test`).
Done 2026-10-21: daemon crash persistence (the daemon counter is the write-through
state file; `tests/uuidv7_daemon_persist_test`). Done 2026-10-28: an unusable state
file fails closed (BDFN: no UUID without the ordering guarantee). Open: the daemon
owner check. Cross-user ordering is planned in `system_service.md`.

## Proposed fix

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
  This alone covers only graceful stops. A daemon crash or power loss loses its
  in-memory state, and explicit-time requests still use the file while the daemon
  runs, so the design and its tests must also cover:
  - crash and restart of the daemon, including after a clock step back;
  - the daemon and file-based allocation running at the same time.
  Options: the daemon writes the file on every allocation (exact, costs a locked
  write per request), or durably reserves ahead (records a high-water mark past
  the values it will serve, so a restart starts beyond it). Reserving ahead
  avoids a write per ID but leaves gaps and, if it reserves time, can push
  timestamps ahead of the clock. Crash safety across power loss also needs fsync,
  not only a write. Until one of these is built and tested, the daemon is not
  crash-persistent.
- Clients refuse a daemon whose peer is a different user (`SO_PEERCRED` on Linux,
  `getpeereid` on macOS).
- An unusable state file fails closed (exit 1), decided 2026-10-28.

Machine-wide across users needs a system service that owns the state (a
systemd, launchd or Windows service with a group-restricted socket). It needs
installation privileges and is not proposed for now. World-writable shared files
are not an option.

Known caveat of a home-based location: a home directory shared between machines
over NFS would share the counter file across them (relying on NFS locking), and
two machines' daemons would contend for one socket path.

## Unguessable state directory (BDFN 2026-10-28)

Failing closed made a fixed name a denial-of-service target: another local user
who creates `/tmp/uuidv7-<uid>` first makes every CLI call of this user exit 1.
BDFN chose an unguessable name instead, remembered where only this user can
write. Linux and macOS only; Windows already uses the private per-user Local
AppData folder.

- The state directory is `/tmp/uuidv7-<uid>-<uuidv7>`: 32 lowercase hex from a
  UUIDv7 made with an in-memory counter (its random bits make the name
  unguessable). It stays in RAM where `/tmp` is.
- The name is remembered in `state-dir` (the full path and a newline) in
  `~/.local/state/uuidv7/`, where `~` is the home directory from the account
  database (`getpwuid(geteuid())`), not `$HOME`. That directory must be private
  (0700, owned by the user, not a symlink). `UUIDV7_STATE_HOME` overrides it
  (tests); `UUIDV7_STATE_DIR` still bypasses all of this.
- A remembered value that does not match `/tmp/uuidv7-<uid>-<32 hex>` exactly is
  ignored, as if absent.
- Fast path, every call: read the remembered name and use the directory,
  creating it if missing (after a reboot `/tmp` is empty and the same name is
  created again).
- `/tmp` can be listed, so the name is not secret while the directory exists. If
  the remembered path exists but is not a directory owned by this user (another
  user created it after a reboot, or planted a symlink or file), a new name is
  chosen and remembered. The lost state was gone anyway, since the directory had
  been removed. A directory of this user's own with group or other access is not
  replaced: that is an error, as before.
- Choosing a name (none remembered, or replacing a squatted one) happens under
  `flock` on `state-dir.lock` beside `state-dir`, re-reading the name after the
  lock is taken, and the new name is written to a temporary file and renamed into
  place. Concurrent first calls therefore agree on one directory.
- Both CLIs and the daemon follow the same protocol, so they share one
  directory. A daemon resolves the name when it starts.
