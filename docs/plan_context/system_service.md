# System service (plan, 2026-10-19)

BDFN chose a layered default: when an installed system service is reachable,
every live request goes to it; otherwise the CLIs keep using the per-user
`/tmp/uuidv7-<uid>` counter file. A fresh machine needs no install, and
installing the service upgrades ordering from per user to machine-wide.

## What the service is

The existing LuaJIT daemon (`lib/uuidv7_daemon.lua`), run by the OS service
manager instead of by a user. It keeps the counter in memory, so no per-call file
I/O. Shared memory (POSIX or SysV) is not needed: one owner process is simpler,
and macOS lacks robust process-shared mutexes.

| | Linux (systemd) | macOS (launchd) | Windows |
|---|---|---|---|
| Socket | `/run/uuidv7/uuidv7.sock` | `/var/run/uuidv7/uuidv7.sock` | `%ProgramData%\uuidv7\uuidv7.sock` |
| Activation | `uuidv7.socket` unit (`SocketMode=0666`), daemon adopts the fd via `LISTEN_FDS` | `LaunchDaemon` plist with a `Sockets` entry (`SockPathMode` 0666), daemon calls `launch_activate_socket` | a small C service host registered with the SCM that runs the daemon (LuaJIT cannot be an SCM service itself) |
| Account | `DynamicUser=yes` | `nobody` | `LocalService` |
| State across restarts | `/run/uuidv7/sequence`, `RuntimeDirectoryPreserve=yes` | `/private/tmp/uuidv7-<service uid>/sequence` by default, configurable with `UUIDV7_STATE_DIR` in the plist | `%ProgramData%\uuidv7\sequence` |

Any local user may request IDs (socket mode 0666). Allocation reveals nothing,
so the only exposure is flooding, which the existing per-request caps bound.

## Client discovery order

1. `UUIDV7_SOCK`, if set.
2. The system socket, if its file exists.
3. The per-user daemon socket in `/tmp/uuidv7-<uid>/`.
4. The per-user counter file.

Clients accept the system socket only if its directory is not writable by
group or other and is owned by root or the service account. Only root can create
those directories, so no other user can plant a socket there.

## Failure policy

- No system socket file: use steps 3 and 4, as today.
- System socket present but refusing to serve: retry, then exit 1. This is the
  same no-silent-fallback rule the per-user daemon has, because other processes
  are drawing from the service and a local value could sort out of order.
- System socket present but the connection is refused (service crashed or
  stopped and the socket file remained): BDFN decided (2026-10-21) that the
  service is restarted up to N times while each affected request fails with
  "no service on this request, restarting; please try again", and after N
  restarts the condition is treated as an error. BDFN decided (2026-10-23) that the
  service manager restarts it, since an unprivileged client cannot restart a
  system service (systemd `Restart=always`
  with `StartLimitBurst=N`, launchd `KeepAlive`, SCM recovery actions), and the
  client counts consecutive refusals in its per-user state directory to switch
  from the restarting message to the error. On Windows the service's DACL could
  instead grant users `SERVICE_START`; not used, for one rule on every OS.
  systemd and launchd keep listening on an activated socket themselves, so this
  mostly arises without socket activation.

## Durability

The daemon writes its counter state to the service state file on every
request, in RAM. `/run` is tmpfs on Linux. On a stock Mac `/var/run` is on
disk, so the macOS state file defaults to `/private/tmp`, which is a RAM disk on
some setups and on disk on a stock Mac, where `UUIDV7_STATE_DIR` in the plist
can point it at a RAM disk. The socket itself can stay in `/var/run/uuidv7/`, since
a socket inode carries no data writes. A user who creates
`/private/tmp/uuidv7-<service uid>` before the service starts makes the
service refuse that directory (a denial of service, not a hijack); `/private/tmp`
is cleared at boot.

Done for the per-user daemon (phase 1, 2026-10-21): its counter is the per-user
state file, taken under the lock once per request (a batch included), so
daemon, `uuidv7` and `uuidv7z` share one sequence and a hard kill loses nothing
(`tests/uuidv7_daemon_persist_test`). Measured on Linux x86_64, file on tmpfs,
daemon and client pinned to separate cores, median of 5 runs: a single request
went from 41.2 to 67.9 µs and a 1000-UUID batch from 3.03 to 3.44 µs per UUID.
The extra cost is 12 syscalls per lock (directory open and check, file open,
flock, read, ftruncate, write, close; strace counts). `pread`/`pwrite` and a
fixed-width record could drop three of them if this matters later.

Phase 2 done (2026-10-23): both clients follow the discovery order and the trust
check above, and the refused-socket policy (exit 75 "please try again" for the
first 3 consecutive refusals, then exit 1; count in the per-user state directory
file `service_refusals`). The count rule is in the Zig core
(`serviceRefusal`, `uuidv7_service_refusal`) with the Lua client as its
differential oracle. `tests/uuidv7_system_socket_test` covers the order, a
classifier over directory modes, a symlinked directory and the refusal
sequence across both CLIs. Not tested: the Windows untrusted-owner case (the
suite cannot create a directory owned by another account); only the trusted
current-user owner is exercised there.

Needed before any service ships (phase 3): the daemon accepts control
commands (`+++`, `r`, `l`) from anyone who can connect. With a socket every
local user can reach, the service must refuse them and leave stop/restart to
the service manager.

## Install

Shipped as files, never installed silently or with automatic `sudo`:
`contrib/systemd/uuidv7.{socket,service}`, `contrib/launchd/<label>.plist`, a
NixOS module in the flake (`nixosModules.default`), and the Windows service host
with `install`/`uninstall` verbs. The README documents each.

## Phases

1. Per-user daemon writes through to the per-user state file and seeds from it.
   Measure the cost.
2. Discovery order and the system-socket trust check in both clients
   (`uuidv7`, `uuidv7z`), with a test-only override for the system socket path.
3. systemd socket activation (`LISTEN_FDS`) in the daemon, the unit files and the
   NixOS module. Verified hermetically with a fake `LISTEN_FDS` handoff, then
   on a real Linux host.
4. launchd socket activation and the plist. Real-host verification needs `sudo`
   on a Mac, with BDFN's approval for that machine.
5. Windows service host. Verified on the Windows test host, with approval for
   installing a service there.

## Tests

Hermetic suites cannot install services. They cover discovery order and the
trust check through a test-only override, the socket-activation handoff by
passing a pre-bound fd, and failure policies with the existing stub daemon.
Real installs are verified per OS by hand, with the commands recorded in this
file.
