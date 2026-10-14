-- uuidv7 platform layer: the only module that touches sockets, poll, signals,
-- process restart and sub-millisecond sleep. POSIX (Linux, macOS) uses BSD sockets
-- on int fds; Windows uses Winsock AF_UNIX sockets (Windows 10 1803+) on SOCKET
-- handles and WSAPoll. Socket identifiers are Lua numbers on both, so they work as
-- table keys. Shared by the daemon and the client; loading it twice is harmless.

local ffi = require("ffi")
local bit = require("bit")
require("uuidv7_core")   -- declares close/unlink/ssize_t/mode_t/timespec first

local is_windows = jit.os == "Windows"
local is_macos = jit.os == "OSX"
local C = ffi.C

local M = { is_windows = is_windows }

-- Longest socket path the platform's sockaddr_un holds, leaving room for the NUL.
M.MAX_PATH = is_macos and 103 or 107

-- Readiness flags returned by poll(), normalized across platforms.
M.READ, M.HUP, M.ERR = 1, 2, 4

-- ===== POSIX =====
local function posix()
	ffi.cdef[[
		typedef unsigned int socklen_t;
		typedef unsigned int uid_t;
		typedef unsigned int gid_t;
		int socket(int domain, int type, int protocol);
		int bind(int sockfd, const void *addr, socklen_t addrlen);
		int listen(int sockfd, int backlog);
		int accept(int sockfd, void *addr, socklen_t *addrlen);
		int connect(int sockfd, const void *addr, socklen_t addrlen);
		ssize_t recv(int sockfd, void *buf, size_t len, int flags);
		ssize_t send(int sockfd, const void *buf, size_t len, int flags);
		int shutdown(int sockfd, int how);
		int fcntl(int fd, int cmd, ...);
		struct pollfd { int fd; short events; short revents; };
		int poll(struct pollfd *fds, unsigned long nfds, int timeout);
		typedef void (*uuidv7_sighandler_t)(int);
		uuidv7_sighandler_t signal(int signum, uuidv7_sighandler_t handler);
		int execv(const char *path, char *const argv[]);
		int setenv(const char *name, const char *value, int overwrite);
		int getpid(void);
		int chmod(const char *path, mode_t mode);
		int getpeereid(int sockfd, uid_t *euid, gid_t *egid);
		int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen);
		struct ucred { int pid; unsigned int uid; unsigned int gid; };
		int nanosleep(const struct timespec *req, struct timespec *rem);
	]]
	if is_macos then
		ffi.cdef[[ struct uuidv7_sockaddr_un { unsigned char sun_len; unsigned char sun_family; char sun_path[104]; }; ]]
	else
		ffi.cdef[[ struct uuidv7_sockaddr_un { unsigned short sun_family; char sun_path[108]; }; ]]
	end
	local AF_UNIX, SOCK_STREAM, SHUT_WR = 1, 1, 1
	local O_NONBLOCK = is_macos and 0x0004 or 0x800
	local F_GETFL, F_SETFL, F_SETFD = 3, 4, 2
	local POLLIN, POLLERR, POLLHUP = 1, 8, 0x10
	local SIGINT, SIGTERM, SIGPIPE = 2, 15, 13
	local SIG_IGN = ffi.cast("uuidv7_sighandler_t", 1)

	local function sockaddr(path)
		local addr = ffi.new("struct uuidv7_sockaddr_un")
		addr.sun_family = AF_UNIX
		if is_macos then addr.sun_len = ffi.sizeof("struct uuidv7_sockaddr_un") end
		ffi.copy(addr.sun_path, path, #path)
		return addr
	end
	local function set_flags(fd, on)
		local fl = tonumber(C.fcntl(fd, F_GETFL, ffi.new("int", 0)))
		fl = on and bit.bor(fl, O_NONBLOCK) or bit.band(fl, bit.bnot(O_NONBLOCK))
		C.fcntl(fd, F_SETFL, ffi.new("int", fl))
	end

	function M.listen(path)
		C.unlink(path)
		local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)
		if fd < 0 then return nil, "socket() failed" end
		local addr = sockaddr(path)
		if C.bind(fd, addr, ffi.sizeof(addr)) ~= 0 then C.close(fd); return nil, "bind() failed on " .. path end
		C.chmod(path, 384)   -- 0600: only the owner may connect
		if C.listen(fd, 64) ~= 0 then C.close(fd); return nil, "listen() failed" end
		set_flags(fd, true)
		return fd
	end
	-- Take over a listener inherited across a restart.
	function M.adopt(fd) set_flags(fd, true); return fd end
	-- Accept one pending connection, or nil. Accepted sockets are made blocking
	-- (macOS/BSD inherit the listener's O_NONBLOCK, so a large send() could be cut
	-- short with EAGAIN) and close-on-exec, so only the listener survives a restart.
	function M.accept(lfd)
		local cfd = tonumber(C.accept(lfd, nil, nil))
		if cfd < 0 then return nil end
		C.fcntl(cfd, F_SETFD, ffi.new("int", 1))
		set_flags(cfd, false)
		return cfd
	end
	function M.connect(path)
		local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)
		if fd < 0 then return nil, "socket() failed" end
		local addr = sockaddr(path)
		if C.connect(fd, addr, ffi.sizeof(addr)) ~= 0 then C.close(fd); return nil, "connect refused" end
		return fd
	end
	function M.recv(fd, buf, n) return tonumber(C.recv(fd, buf, n, 0)) end
	function M.send(fd, p, n) return tonumber(C.send(fd, p, n, 0)) end
	function M.shutdown_write(fd) C.shutdown(fd, SHUT_WR) end
	function M.close(fd) C.close(fd) end
	-- fds: array of socket numbers. Returns { [fd] = READ|HUP|ERR bits } for ready ones.
	function M.poll(fds, timeout_ms)
		local n = #fds
		local pa = ffi.new("struct pollfd[?]", n)
		for i = 1, n do pa[i - 1].fd = fds[i]; pa[i - 1].events = POLLIN end
		local ready = {}
		if tonumber(C.poll(pa, n, timeout_ms)) > 0 then
			for i = 0, n - 1 do
				local re = pa[i].revents
				if re ~= 0 then
					local f = 0
					if bit.band(re, POLLIN) ~= 0 then f = bit.bor(f, M.READ) end
					if bit.band(re, POLLHUP) ~= 0 then f = bit.bor(f, M.HUP) end
					if bit.band(re, POLLERR) ~= 0 then f = bit.bor(f, M.ERR) end
					ready[pa[i].fd] = f
				end
			end
		end
		return ready
	end
	-- Peer UID for logging; never throws. getpeereid is an undefined ffi.C symbol in
	-- nix's Linux glibc, so even touching it raises: macOS -> getpeereid; Linux ->
	-- SO_PEERCRED; any failure -> nil.
	function M.peer_uid(fd)
		local ok, uid = pcall(function()
			if is_macos then
				local euid, egid = ffi.new("uid_t[1]"), ffi.new("gid_t[1]")
				if C.getpeereid(fd, euid, egid) == 0 then return tonumber(euid[0]) end
			else
				local cred = ffi.new("struct ucred")
				local len = ffi.new("socklen_t[1]", ffi.sizeof("struct ucred"))
				if C.getsockopt(fd, 1, 17, cred, len) == 0 then return tonumber(cred.uid) end
			end
		end)
		return ok and uid or nil
	end
	function M.getpid() return tonumber(C.getpid()) end
	-- SIGINT/SIGTERM set stop[0]; SIGPIPE is ignored so a vanished client cannot kill us.
	function M.install_stop_signals(stop)
		local function on_signal() stop[0] = 1 end
		jit.off(on_signal)
		local cb = ffi.cast("uuidv7_sighandler_t", on_signal)
		C.signal(SIGINT, cb); C.signal(SIGTERM, cb); C.signal(SIGPIPE, SIG_IGN)
	end
	-- Restart in place: re-exec `exe --daemon`, keeping the listener as UUIDV7_LISTEN_FD.
	function M.handoff(lfd, exe)
		C.fcntl(lfd, F_SETFD, ffi.new("int", 0))   -- clear CLOEXEC so the fd survives exec
		C.setenv("UUIDV7_LISTEN_FD", tostring(lfd), 1)
		local argv = ffi.new("char*[3]")
		local e = ffi.new("char[?]", #exe + 1); ffi.copy(e, exe)
		local flag = ffi.new("char[?]", 9); ffi.copy(flag, "--daemon")
		argv[0] = e; argv[1] = flag; argv[2] = nil
		C.execv(exe, argv)
		return false
	end
	function M.sleep_us(us)
		if not us or us <= 0 then return end
		local ts = ffi.new("struct timespec")
		ts.tv_sec = math.floor(us / 1000000)
		ts.tv_nsec = math.floor((us % 1000000) * 1000)
		C.nanosleep(ts, nil)
	end
	function M.ensure_dir(dir)
		os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
	end
end

-- ===== Windows =====
local function windows()
	ffi.cdef[[
		typedef uintptr_t uuidv7_SOCKET;
		typedef struct { uint16_t wVersion, wHighVersion; uint16_t iMaxSockets, iMaxUdpDg;
			char *lpVendorInfo; char szDescription[257]; char szSystemStatus[129]; } uuidv7_WSADATA;
		int WSAStartup(uint16_t version, uuidv7_WSADATA *data);
		int WSAGetLastError(void);
		uuidv7_SOCKET socket(int af, int type, int protocol);
		int bind(uuidv7_SOCKET s, const void *addr, int len);
		int listen(uuidv7_SOCKET s, int backlog);
		uuidv7_SOCKET accept(uuidv7_SOCKET s, void *addr, int *len);
		int connect(uuidv7_SOCKET s, const void *addr, int len);
		int send(uuidv7_SOCKET s, const char *buf, int len, int flags);
		int recv(uuidv7_SOCKET s, char *buf, int len, int flags);
		int shutdown(uuidv7_SOCKET s, int how);
		int closesocket(uuidv7_SOCKET s);
		int ioctlsocket(uuidv7_SOCKET s, long cmd, unsigned long *argp);
		typedef struct { uuidv7_SOCKET fd; short events; short revents; } uuidv7_WSAPOLLFD;
		int WSAPoll(uuidv7_WSAPOLLFD *fds, unsigned long n, int timeout);
		struct uuidv7_sockaddr_un { unsigned short sun_family; char sun_path[108]; };
		int SetHandleInformation(void *h, uint32_t mask, uint32_t flags);
		uint32_t GetCurrentProcessId(void);
		uint32_t GetModuleFileNameA(void *module, char *buf, uint32_t size);
		int SetEnvironmentVariableA(const char *name, const char *value);
		void Sleep(uint32_t ms);
		int QueryPerformanceCounter(int64_t *count);
		int QueryPerformanceFrequency(int64_t *freq);
	]]
	local W = ffi.load("ws2_32")
	assert(W.WSAStartup(0x0202, ffi.new("uuidv7_WSADATA")) == 0, "WSAStartup failed")
	local AF_UNIX, SOCK_STREAM, SD_SEND = 1, 1, 1
	local FIONBIO = ffi.cast("long", 0x8004667E)
	local POLLRDNORM, POLLERR, POLLHUP = 0x0100, 0x0001, 0x0002
	local HANDLE_FLAG_INHERIT = 1
	local INVALID = ffi.cast("uuidv7_SOCKET", -1)

	local function sock(n) return ffi.cast("uuidv7_SOCKET", n) end
	local function num(s) return tonumber(ffi.cast("uintptr_t", s)) end
	local function sockaddr(path)
		local addr = ffi.new("struct uuidv7_sockaddr_un")
		addr.sun_family = AF_UNIX
		ffi.copy(addr.sun_path, path, #path)
		return addr
	end
	local function set_nonblocking(s, on) W.ioctlsocket(s, FIONBIO, ffi.new("unsigned long[1]", on and 1 or 0)) end
	local function set_inherit(s, on)
		C.SetHandleInformation(ffi.cast("void*", s), HANDLE_FLAG_INHERIT, on and HANDLE_FLAG_INHERIT or 0)
	end

	-- Access control comes from the socket file living in the per-user temp
	-- directory; Winsock has no chmod or peer-credential call for AF_UNIX.
	function M.listen(path)
		os.remove(path)
		local s = W.socket(AF_UNIX, SOCK_STREAM, 0)
		if s == INVALID then return nil, "socket() failed (WSA " .. W.WSAGetLastError() .. ")" end
		local addr = sockaddr(path)
		if W.bind(s, addr, ffi.sizeof(addr)) ~= 0 then
			local e = W.WSAGetLastError(); W.closesocket(s)
			return nil, "bind() failed on " .. path .. " (WSA " .. e .. ")"
		end
		if W.listen(s, 64) ~= 0 then W.closesocket(s); return nil, "listen() failed" end
		set_inherit(s, false)
		set_nonblocking(s, true)
		return num(s)
	end
	function M.adopt(n) local s = sock(n); set_inherit(s, false); set_nonblocking(s, true); return n end
	-- Accepted sockets inherit the listener's non-blocking mode and Winsock's default
	-- inheritability; make them blocking and private so only the listener is handed off.
	function M.accept(ln)
		local s = W.accept(sock(ln), nil, nil)
		if s == INVALID then return nil end
		set_nonblocking(s, false)
		set_inherit(s, false)
		return num(s)
	end
	function M.connect(path)
		local s = W.socket(AF_UNIX, SOCK_STREAM, 0)
		if s == INVALID then return nil, "socket() failed" end
		local addr = sockaddr(path)
		if W.connect(s, addr, ffi.sizeof(addr)) ~= 0 then W.closesocket(s); return nil, "connect refused" end
		set_inherit(s, false)
		return num(s)
	end
	function M.recv(n, buf, len) return tonumber(W.recv(sock(n), buf, len, 0)) end
	function M.send(n, p, len) return tonumber(W.send(sock(n), p, len, 0)) end
	function M.shutdown_write(n) W.shutdown(sock(n), SD_SEND) end
	function M.close(n) W.closesocket(sock(n)) end
	function M.poll(fds, timeout_ms)
		local n = #fds
		local pa = ffi.new("uuidv7_WSAPOLLFD[?]", n)
		for i = 1, n do pa[i - 1].fd = sock(fds[i]); pa[i - 1].events = POLLRDNORM end
		local ready = {}
		if tonumber(W.WSAPoll(pa, n, timeout_ms)) > 0 then
			for i = 0, n - 1 do
				local re = pa[i].revents
				if re ~= 0 then
					local f = 0
					if bit.band(re, POLLRDNORM) ~= 0 then f = bit.bor(f, M.READ) end
					if bit.band(re, POLLHUP) ~= 0 then f = bit.bor(f, M.HUP) end
					if bit.band(re, POLLERR) ~= 0 then f = bit.bor(f, M.ERR) end
					ready[fds[i + 1]] = f
				end
			end
		end
		return ready
	end
	function M.peer_uid() return nil end
	function M.getpid() return tonumber(C.GetCurrentProcessId()) end
	-- Console control events arrive on another thread, which a LuaJIT callback cannot
	-- safely serve, so Ctrl-C keeps its default effect (end the process). The next
	-- start removes a stale socket file before binding.
	function M.install_stop_signals() end
	-- Restart by handoff: there is no exec on Windows, so start a successor that
	-- inherits the listener (UUIDV7_LISTEN_FD) and the same stdout, then let the
	-- caller exit. Clients see no gap because the listener never closes.
	function M.handoff(ln, exe)
		local s = sock(ln)
		set_inherit(s, true)
		C.SetEnvironmentVariableA("UUIDV7_LISTEN_FD", tostring(ln))
		local buf = ffi.new("char[1024]")
		local len = C.GetModuleFileNameA(nil, buf, 1024)
		if len == 0 then return false end
		local luajit = ffi.string(buf, len)
		local cmd = string.format('start "" /b "%s" "%s" --daemon', luajit, exe)
		local r = os.execute(cmd)
		return r == 0 or r == true
	end
	-- Sleep() has millisecond granularity; wait out shorter backoffs on the
	-- performance counter instead.
	local freq = ffi.new("int64_t[1]")
	C.QueryPerformanceFrequency(freq)
	function M.sleep_us(us)
		if not us or us <= 0 then return end
		if us >= 2000 then C.Sleep(math.floor(us / 1000)); return end
		local t0, t = ffi.new("int64_t[1]"), ffi.new("int64_t[1]")
		C.QueryPerformanceCounter(t0)
		local ticks = freq[0] * us / 1000000LL
		repeat C.Sleep(0); C.QueryPerformanceCounter(t) until t[0] - t0[0] >= ticks
	end
	function M.ensure_dir(dir)
		os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
	end
end

if is_windows then windows() else posix() end

return M
