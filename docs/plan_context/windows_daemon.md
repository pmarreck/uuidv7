# Windows daemon port: context

Decision: the BDFN chose option C2 on 2026-10-14. That option is a Windows daemon on
Winsock AF_UNIX sockets and WSAPoll, with a Windows-compatible restart mechanism.

## Feasibility spikes (2026-10-14, Windows 10 22H2 build 19045, x86_64, static LuaJIT)

- An AF_UNIX stream socket works through LuaJIT FFI against `ws2_32`. The spike
  covered `socket(1, 1, 0)`, `bind` and `listen` on a path in `%TEMP%` (one
  containing a space), and `ioctlsocket(FIONBIO)`. `WSAPoll` reported the
  pending accept as `POLLRDNORM` (0x0100), and `accept`, `send` and `recv`
  round-tripped.
- Restart by handoff works. The parent marks the listening socket inheritable
  (`SetHandleInformation(HANDLE_FLAG_INHERIT)`) and starts a successor with the
  handle value (`start "" /b`), and then exits. The successor accepts on that
  handle and serves a client that connects after the parent is gone. This
  replaces Unix `execv` with the listener fd in `UUIDV7_LISTEN_FD`; the PID
  changes on Windows.

## Known differences from Unix

- Winsock has no peer-credential call for AF_UNIX (no `getpeereid` or
  `SO_PEERCRED`), so peer UID logging is absent. Access control relies on the
  socket file being in the per-user temp directory, under that directory's ACL.
- `WSAPoll` uses different event bits: POLLRDNORM 0x0100, POLLERR 0x0001 and
  POLLHUP 0x0002.
- Sockets are `SOCKET` (`uintptr_t`) handles rather than `int` fds. Winsock
  needs `WSAStartup` and `closesocket`, and `ioctlsocket` replaces `fcntl`.
- The test suites start the daemon through `io.popen`, which uses `cmd.exe` on
  Windows. They need a portable launcher.
