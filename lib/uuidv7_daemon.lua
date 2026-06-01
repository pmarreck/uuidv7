-- uuidv7 daemon: a single-threaded, poll(2)-based Unix-domain-socket server that
-- dispenses UUIDv7 values. Single process => the live counter is in-memory and the
-- cross-process monotonicity problem disappears. Zero deps (LuaJIT + FFI).

local core = require("uuidv7_core")
local json = require("uuidv7_json")
local ffi = require("ffi")
local bit = require("bit")

local is_macos = jit.os == "OSX"

-- Only NEW symbols (core already cdef'd the generic libc/time/random ones).
ffi.cdef[[
	typedef unsigned int socklen_t;
	typedef unsigned int uid_t;
	typedef unsigned int gid_t;
	int socket(int domain, int type, int protocol);
	int bind(int sockfd, const void *addr, socklen_t addrlen);
	int listen(int sockfd, int backlog);
	int accept(int sockfd, void *addr, socklen_t *addrlen);
	ssize_t recv(int sockfd, void *buf, size_t len, int flags);
	ssize_t send(int sockfd, const void *buf, size_t len, int flags);
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
]]
if is_macos then
	ffi.cdef[[ struct sockaddr_un { unsigned char sun_len; unsigned char sun_family; char sun_path[104]; }; ]]
else
	ffi.cdef[[ struct sockaddr_un { unsigned short sun_family; char sun_path[108]; }; ]]
end

local C = ffi.C

local AF_UNIX, SOCK_STREAM = 1, 1
local O_NONBLOCK = is_macos and 0x0004 or 0x800
local F_GETFL, F_SETFL, F_SETFD = 3, 4, 2
local POLLIN, POLLERR, POLLHUP = 1, 8, 0x10
local SIGINT, SIGTERM, SIGPIPE = 2, 15, 13
local SIG_IGN = ffi.cast("uuidv7_sighandler_t", 1)
local MAX_LINE = 64

local M = {}
local server   -- per-run state

-- ===== paths =====
local function strip_slash(p) return (p:gsub("/+$", "")) end

local function socket_path()
	if os.getenv("UUIDV7_SOCK") then return os.getenv("UUIDV7_SOCK") end
	local base = os.getenv("XDG_RUNTIME_DIR") or os.getenv("TMPDIR") or "/tmp"
	return strip_slash(base) .. "/uuidv7.sock"
end

local function log_path()
	if os.getenv("UUIDV7_LOG") then return os.getenv("UUIDV7_LOG") end
	local xdg = os.getenv("XDG_STATE_HOME")
	if xdg then return strip_slash(xdg) .. "/uuidv7/uuidv7.log" end
	local home = os.getenv("HOME") or "."
	if is_macos then return home .. "/Library/Logs/uuidv7.log" end
	return home .. "/.local/state/uuidv7/uuidv7.log"
end

local function ensure_dir(path)
	local dir = path:match("^(.*)/[^/]+$")
	if dir and dir ~= "" then os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null") end
end

-- ===== time / logging =====
local function now_parts()
	local ns = core.get_nanotime()
	local ms_total = ns / 1000000LL
	local sec = tonumber(ms_total / 1000LL)
	local ms = tonumber(ms_total % 1000LL)
	return os.date("!%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03dZ", ms), tonumber(ms_total)
end

local function log_event(event, extra)
	if not server.logfh then return end
	local iso, ms = now_parts()
	local rec = { v = 1, ts = iso, ts_ms = ms, event = event }
	if extra then for k, v in pairs(extra) do rec[k] = v end end
	server.logfh:write(json.encode(rec) .. "\n")
	server.logfh:flush()
end

-- ===== stats =====
local function stats_table()
	local iso = now_parts()
	local up_ns = core.get_nanotime() - server.start_ns
	return {
		version = core.VERSION,
		pid = tonumber(C.getpid()),
		socket = server.sock_path,
		started = server.start_iso,
		now = iso,
		uptime_s = tonumber(up_ns / 1000000000LL),
		requests = server.requests,
		uuids_served = server.uuids_served,
		last_batch = server.last_batch,
		peak_batch = server.peak_batch,
		max_batch = server.max_batch,
		same_ns_bumps = server.k_same_ns,
		rollback_events = server.k_rollback,
		ts_ahead_events = server.k_ts_ahead,
		insecure_rng = server.insecure_rng,
		conns_open = server.conns_open,
		conns_served = server.conns_served,
		retries = server.retries,
	}
end

local STAT_ORDER = {
	"version", "pid", "socket", "started", "now", "uptime_s", "requests",
	"uuids_served", "last_batch", "peak_batch", "max_batch", "same_ns_bumps",
	"rollback_events", "ts_ahead_events", "insecure_rng", "conns_open", "conns_served", "retries",
}
local function stats_human()
	local s = stats_table()
	local out = {}
	for _, k in ipairs(STAT_ORDER) do
		out[#out + 1] = string.format("%-16s %s", k .. ":", tostring(s[k]))
	end
	return table.concat(out, "\n") .. "\n"
end
local function stats_json()
	local s = stats_table()
	s.event = "stats"
	return json.encode(s) .. "\n"
end

local HELP = table.concat({
	"uuidv7 daemon protocol (UDS, line-based, newline-terminated):",
	"  <empty>     one compact UUIDv7",
	"  c<N>        request N UUIDs",
	"  -           hyphenated output",
	"  tn<ns>      explicit time, nanoseconds",
	"  tm<ms>      explicit time, milliseconds",
		"  *           ephemeral (needs tn/tm): isolated, never affects the live stream",
		"  R<n> W<us>  client retry telemetry: attempt # and microseconds waited (logged)",
		"  example: c5-tm1700000000000",
	"  PING->OK  s->status(text)  sj->status(JSON)  l->log stats",
	"  r->restart  +++ ->shutdown  h or ? ->this help",
	"  handshake (no newline): SYN(0x16) -> SYNACK(0x16 0x06) -> ACK(0x06)",
	"",
}, "\n")

-- ===== protocol parser =====
local CTL = { s = true, sj = true, l = true, r = true, h = true, ["?"] = true, PING = true, ["+++"] = true }

local function parse_request(line)
	if CTL[line] then return { kind = "ctl", verb = line } end
	local count, hyphens, time_ns, ephemeral, time_seen = 1, false, nil, false, false
	-- Optional client retry telemetry: R<attempt> and W<microseconds waited so far>.
	local retry_attempt, waited_us = nil, nil
	local i, n = 1, #line
	while i <= n do
		local c = line:sub(i, i)
		if c == "-" then hyphens = true; i = i + 1
		elseif c == "*" then ephemeral = true; i = i + 1
		elseif c == "c" then
			local d = line:match("^(%d+)", i + 1)
			if not d then return { kind = "err", msg = "c needs a number" } end
			count = tonumber(d); i = i + 1 + #d
		elseif c == "t" then
			if time_seen then return { kind = "err", msg = "duplicate time token" } end
			local unit = line:sub(i + 1, i + 1)
			if unit ~= "n" and unit ~= "m" then return { kind = "err", msg = "time unit must be n or m" } end
			local d = line:match("^(%d+)", i + 2)
			if not d then return { kind = "err", msg = "time needs digits" } end
			local v = core.parse_static(d)
			if unit == "m" then v = v * 1000000LL end
			time_ns = v; time_seen = true; i = i + 2 + #d
		elseif c == "R" then
			local d = line:match("^(%d+)", i + 1)
			if not d then return { kind = "err", msg = "R needs a number" } end
			retry_attempt = tonumber(d); i = i + 1 + #d
		elseif c == "W" then
			local d = line:match("^(%d+)", i + 1)
			if not d then return { kind = "err", msg = "W needs a number" } end
			waited_us = tonumber(d); i = i + 1 + #d
		else
			return { kind = "err", msg = "unknown token '" .. c .. "'" }
		end
	end
	if time_seen and time_ns < 0LL then return { kind = "err", msg = "timestamp out of range" } end
	if ephemeral and not time_seen then return { kind = "err", msg = "* requires tn/tm" } end
	if count < 1 then return { kind = "err", msg = "count must be >= 1" } end
	if count > server.max_batch then return { kind = "err", msg = "too many requested (max " .. server.max_batch .. ")" } end
	return { kind = "gen", count = count, hyphens = hyphens, time = time_ns, ephemeral = ephemeral,
		retry_attempt = retry_attempt, waited_us = waited_us }
end

local function do_generate(req)
	local counter, time
	if req.ephemeral then
		counter = core.new_counter("memory")   -- transient: never touches the live stream
		time = req.time
	elseif req.time ~= nil then
		local now = core.get_nanotime()
		if req.time > now + 1000000000LL then
			return nil, "timestamp more than 1s in the future (add * for ephemeral)"
		end
		counter, time = server.counter, req.time
	else
		counter, time = server.counter, nil
	end
	local lines, kinds = core.generate(counter, { time = time, hyphens = req.hyphens, count = req.count })
	if not req.ephemeral then
		server.k_same_ns = server.k_same_ns + (kinds.same_ns or 0)
		server.k_rollback = server.k_rollback + (kinds.rollback or 0)
		server.k_ts_ahead = server.k_ts_ahead + (kinds.ts_ahead or 0)
	end
	server.uuids_served = server.uuids_served + req.count
	server.last_batch = req.count
	if req.count > server.peak_batch then server.peak_batch = req.count end
	return table.concat(lines, "\n") .. "\n"
end

-- ===== fd / socket helpers =====
local function set_nonblock(fd)
	local fl = tonumber(C.fcntl(fd, F_GETFL, ffi.new("int", 0)))
	C.fcntl(fd, F_SETFL, ffi.new("int", bit.bor(fl, O_NONBLOCK)))
end

-- Force a fd blocking. macOS/BSD accept() inherits O_NONBLOCK from the listener
-- (Linux does not), so accepted conns must be made blocking explicitly or large
-- send()s get truncated at the socket buffer with EAGAIN.
local function set_block(fd)
	local fl = tonumber(C.fcntl(fd, F_GETFL, ffi.new("int", 0)))
	C.fcntl(fd, F_SETFL, ffi.new("int", bit.band(fl, bit.bnot(O_NONBLOCK))))
end

local function send_all(fd, s)
	local p = ffi.cast("const char*", s)
	local total, sent = #s, 0
	while sent < total do
		local nrec = tonumber(C.send(fd, p + sent, total - sent, 0))
		if nrec <= 0 then return false end
		sent = sent + nrec
	end
	return true
end
local function send_line(fd, s) return send_all(fd, s .. "\n") end

-- Peer UID for logging. MUST never throw: getpeereid exists on macOS/BSD but is an
-- UNDEFINED symbol in nix's Linux glibc for ffi.C, so even touching C.getpeereid raises.
-- macOS -> getpeereid; Linux -> SO_PEERCRED; any failure -> nil.
local function peer_uid(fd)
	local ok, uid = pcall(function()
		if is_macos then
			local euid = ffi.new("uid_t[1]")
			local egid = ffi.new("gid_t[1]")
			if C.getpeereid(fd, euid, egid) == 0 then return tonumber(euid[0]) end
		else
			local cred = ffi.new("struct ucred")
			local len = ffi.new("socklen_t[1]", ffi.sizeof("struct ucred"))
			if C.getsockopt(fd, 1, 17, cred, len) == 0 then return tonumber(cred.uid) end -- SOL_SOCKET, SO_PEERCRED
		end
		return nil
	end)
	return ok and uid or nil
end

-- ===== lifecycle =====
local function resolve_exe(a0)
	if not a0 or a0 == "" then return "uuidv7" end
	if a0:sub(1, 1) == "/" then return a0 end
	if a0:find("/") then return (os.getenv("PWD") or ".") .. "/" .. a0 end
	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local p = dir .. "/" .. a0
		local f = io.open(p, "r")
		if f then f:close(); return p end
	end
	return a0
end

local function close_log()
	if server.logfh then server.logfh:flush(); server.logfh:close(); server.logfh = nil end
end

local function shutdown(reason)
	local s = stats_table(); s.reason = reason
	log_event("shutdown", s)
	close_log()
	C.unlink(server.sock_path)
	os.exit(0)
end

local function restart()
	log_event("restart", stats_table())
	close_log()
	C.fcntl(server.listen_fd, F_SETFD, ffi.new("int", 0))   -- clear CLOEXEC so the fd survives exec
	C.setenv("UUIDV7_LISTEN_FD", tostring(server.listen_fd), 1)
	local argv = ffi.new("char*[3]")
	local exe = ffi.new("char[?]", #server.exe + 1); ffi.copy(exe, server.exe)
	local flag = ffi.new("char[?]", 9); ffi.copy(flag, "--daemon")
	argv[0] = exe; argv[1] = flag; argv[2] = nil
	C.execv(server.exe, argv)
	io.stderr:write("uuidv7 daemon: re-exec failed\n")
	os.exit(1)
end

-- ===== per-connection processing =====
local conns = {}
local function close_conn(fd)
	if conns[fd] then conns[fd] = nil; C.close(fd); server.conns_open = server.conns_open - 1 end
end

local function dispatch(fd, line)
	server.requests = server.requests + 1
	local req = parse_request(line)
	if req.kind == "err" then
		send_line(fd, "ERR " .. req.msg)
		log_event("error", { request = line, reason = req.msg, peer_uid = peer_uid(fd) })
		return
	end
	if req.kind == "ctl" then
		local v = req.verb
		if v == "PING" then send_line(fd, "OK")
		elseif v == "s" then send_all(fd, stats_human())
		elseif v == "sj" then send_all(fd, stats_json())
		elseif v == "l" then log_event("stats", stats_table()); send_line(fd, "OK")
		elseif v == "h" or v == "?" then send_all(fd, HELP)
		elseif v == "r" then send_line(fd, "OK"); restart()
		elseif v == "+++" then send_line(fd, "OK"); shutdown("command")
		end
		return
	end
	if req.retry_attempt then
		server.retries = server.retries + 1
		log_event("retry", { request = line, attempt = req.retry_attempt,
			waited_us = req.waited_us, peer_uid = peer_uid(fd) })
	end
	local resp, err = do_generate(req)
	if not resp then
		send_line(fd, "ERR " .. err)
		log_event("error", { request = line, reason = err, peer_uid = peer_uid(fd) })
	else
		send_all(fd, resp)
	end
end

-- returns false if the connection should be closed
local function process(conn, fd)
	while conn.hs ~= "line" and #conn.buf > 0 do
		local b = conn.buf:byte(1)
		if conn.hs == "start" then
			if b == 0x16 then            -- SYN
				conn.buf = conn.buf:sub(2)
				send_all(fd, "\22\6")    -- SYNACK = 0x16 0x06
				conn.hs = "await_ack"
			else
				conn.hs = "line"
			end
		elseif conn.hs == "await_ack" then
			if b == 0x06 then conn.buf = conn.buf:sub(2) end   -- consume ACK
			conn.hs = "line"
		end
	end
	if conn.hs ~= "line" then return true end
	while true do
		local nl = conn.buf:find("\n", 1, true)
		if not nl then
			if #conn.buf > MAX_LINE then
				send_line(fd, "ERR line too long (max " .. MAX_LINE .. ")")
				log_event("error", { request = conn.buf:sub(1, MAX_LINE), reason = "line too long", peer_uid = peer_uid(fd) })
				conn.buf = ""
			end
			return true
		end
		local line = conn.buf:sub(1, nl - 1)
		conn.buf = conn.buf:sub(nl + 1)
		if #line > MAX_LINE then
			send_line(fd, "ERR line too long (max " .. MAX_LINE .. ")")
			log_event("error", { request = line:sub(1, MAX_LINE), reason = "line too long", peer_uid = peer_uid(fd) })
		else
			-- A bad request must NEVER crash the daemon: contain any handler error.
			local handled, derr = pcall(dispatch, fd, line)
			if not handled then
				send_line(fd, "ERR internal error")
				log_event("error", { request = line, reason = "internal: " .. tostring(derr), peer_uid = peer_uid(fd) })
			end
		end
	end
end

-- ===== bind / adopt =====
local function make_listener()
	local adopted = os.getenv("UUIDV7_LISTEN_FD")
	if adopted then
		local fd = tonumber(adopted)
		set_nonblock(fd)
		return fd, true
	end
	local path = server.sock_path
	assert(#path < 100, "socket path too long: " .. path)
	ensure_dir(path)
	C.unlink(path)
	local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)
	assert(fd >= 0, "socket() failed")
	local addr = ffi.new("struct sockaddr_un")
	addr.sun_family = AF_UNIX
	if is_macos then addr.sun_len = ffi.sizeof("struct sockaddr_un") end
	ffi.copy(addr.sun_path, path, #path)
	assert(C.bind(fd, addr, ffi.sizeof("struct sockaddr_un")) == 0, "bind() failed on " .. path)
	C.chmod(path, 384)   -- 0600
	assert(C.listen(fd, 64) == 0, "listen() failed")
	set_nonblock(fd)
	return fd, false
end

local function open_logfh()
	local p = log_path()
	ensure_dir(p)
	return io.open(p, "a")
end

function M.run(opts)
	opts = opts or {}
	server = {
		sock_path = socket_path(),
		exe = resolve_exe(opts.arg0 or (arg and arg[0])),
		max_batch = tonumber(os.getenv("UUIDV7_MAX_BATCH")) or 1000,
		counter = core.new_counter("memory"),
		requests = 0, uuids_served = 0, last_batch = 0, peak_batch = 0,
		k_same_ns = 0, k_rollback = 0, k_ts_ahead = 0, insecure_rng = 0,
		conns_open = 0, conns_served = 0, retries = 0,
		start_ns = core.get_nanotime(),
	}
	server.start_iso = (now_parts())
	server.logfh = open_logfh()

	local listen_fd, adopted = make_listener()
	server.listen_fd = listen_fd
	log_event(adopted and "restart-ready" or "start",
		{ pid = tonumber(C.getpid()), version = core.VERSION, socket = server.sock_path, adopted = adopted })

	-- Readiness line: emitted to stdout the moment we're listening. Lets supervisors
	-- (and the test harness) synchronize on "ready" instead of sleeping/polling.
	-- Survives re-exec, so it also signals that a restart has finished.
	io.write("UUIDV7-LISTENING " .. server.sock_path .. "\n")
	io.flush()

	-- signals: ignore SIGPIPE; SIGINT/SIGTERM set a stop flag checked by the loop
	local stop = ffi.new("int[1]", 0)
	local function on_signal() stop[0] = 1 end
	jit.off(on_signal)
	local cb = ffi.cast("uuidv7_sighandler_t", on_signal)
	C.signal(SIGINT, cb); C.signal(SIGTERM, cb); C.signal(SIGPIPE, SIG_IGN)

	while stop[0] == 0 do
		local fds = { listen_fd }
		for fd in pairs(conns) do fds[#fds + 1] = fd end
		local nf = #fds
		local pa = ffi.new("struct pollfd[?]", nf)
		for i = 1, nf do pa[i - 1].fd = fds[i]; pa[i - 1].events = POLLIN; pa[i - 1].revents = 0 end
		local r = tonumber(C.poll(pa, nf, 1000))
		if stop[0] ~= 0 then break end
		if r and r > 0 then
			for i = 0, nf - 1 do
				local re = pa[i].revents
				if re ~= 0 then
					local fd = pa[i].fd
					if fd == listen_fd then
						while true do
							local cfd = tonumber(C.accept(listen_fd, nil, nil))
							if cfd < 0 then break end
							-- accepted conns stay blocking; poll(POLLIN) gates recv, send is small.
							-- FD_CLOEXEC so client conns do NOT survive a re-exec (only the
							-- listener should) -- otherwise restart leaks them and clients hang.
							C.fcntl(cfd, F_SETFD, ffi.new("int", 1))
							set_block(cfd)   -- macOS inherits the listener's O_NONBLOCK; undo it
							conns[cfd] = { buf = "", hs = "start" }
							server.conns_open = server.conns_open + 1
							server.conns_served = server.conns_served + 1
						end
					elseif bit.band(re, bit.bor(POLLIN, POLLHUP)) ~= 0 then
						-- read FIRST even if POLLHUP is set: a client that shut its write
						-- side (oneshot) delivers POLLIN+POLLHUP together; the request is
						-- still pending. Only close once recv actually drains to EOF.
						local rb = ffi.new("char[?]", 4096)
						local nr = tonumber(C.recv(fd, rb, 4096, 0))
						if nr <= 0 then
							close_conn(fd)
						else
							local conn = conns[fd]
							conn.buf = conn.buf .. ffi.string(rb, nr)
							if process(conn, fd) == false then close_conn(fd) end
						end
					elseif bit.band(re, POLLERR) ~= 0 then
						close_conn(fd)
					end
				end
			end
		end
	end
	shutdown("signal")
end

return M
