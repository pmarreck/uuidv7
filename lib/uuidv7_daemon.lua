-- uuidv7 daemon: a single-threaded, poll-based Unix-domain-socket server that
-- dispenses UUIDv7 values (POSIX poll(2), or Winsock AF_UNIX + WSAPoll on Windows;
-- see uuidv7_net). The live counter is the same locked per-user state file the
-- standalone CLIs use (in RAM under /tmp), read and written on every allocation,
-- so the daemon and file-based callers share one sequence and a crash or restart
-- loses nothing. Zero deps (LuaJIT + FFI).

local core = require("uuidv7_core")
local json = require("uuidv7_json")
local net = require("uuidv7_net")
local ffi = require("ffi")
local bit = require("bit")

local is_macos = jit.os == "OSX"
local is_windows = net.is_windows

local MAX_LINE = 64

local M = {}
local server   -- per-run state

-- ===== paths =====
local function strip_slash(p) return (p:gsub("/+$", "")) end

-- $UUIDV7_SOCK, else uuidv7.sock in the per-user state directory, the same
-- lookup the clients use (see core.state_dir).
local function socket_path()
	if os.getenv("UUIDV7_SOCK") then return os.getenv("UUIDV7_SOCK") end
	return assert(core.state_file("uuidv7.sock"),
		"no per-user state directory for the socket; set UUIDV7_STATE_DIR or UUIDV7_SOCK")
end

local function log_path()
	if os.getenv("UUIDV7_LOG") then return os.getenv("UUIDV7_LOG") end
	local xdg = os.getenv("XDG_STATE_HOME")
	if xdg then return strip_slash(xdg) .. "/uuidv7/uuidv7.log" end
	if is_windows and os.getenv("LOCALAPPDATA") then
		return strip_slash(os.getenv("LOCALAPPDATA")) .. "/uuidv7/uuidv7.log"
	end
	local home = os.getenv("HOME") or "."
	if is_macos then return home .. "/Library/Logs/uuidv7.log" end
	return home .. "/.local/state/uuidv7/uuidv7.log"
end

local function ensure_dir(path)
	local dir = path:match("^(.*)[/\\][^/\\]+$")
	if dir and dir ~= "" then net.ensure_dir(dir) end
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
		pid = net.getpid(),
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
			if v and unit == "m" then v = core.ms_to_ns(v) end
			if not v then return { kind = "err", msg = "timestamp out of range" } end
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

local function send_all(fd, s)
	local p = ffi.cast("const char*", s)
	local total, sent = #s, 0
	while sent < total do
		local nrec = net.send(fd, p + sent, total - sent)
		if nrec <= 0 then return false end
		sent = sent + nrec
	end
	return true
end
local function send_line(fd, s) return send_all(fd, s .. "\n") end

local peer_uid = net.peer_uid

-- ===== lifecycle =====
local function resolve_exe(a0)
	if not a0 or a0 == "" then return "uuidv7" end
	if a0:sub(1, 1) == "/" or a0:match("^%a:[/\\]") then return a0 end
	if a0:find("[/\\]") then return (os.getenv("PWD") or ".") .. "/" .. a0 end
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
	-- A socket file the service manager created stays: it keeps listening on it.
	if server.owns_socket then os.remove(server.sock_path) end
	os.exit(0)
end

local function restart()
	log_event("restart", stats_table())
	close_log()
	-- POSIX re-execs in place; Windows starts a successor that inherits the listener.
	-- Either way the listener never closes, so clients see no gap.
	if net.handoff(server.listen_fd, server.exe) and is_windows then os.exit(0) end
	io.stderr:write("uuidv7 daemon: restart failed\n")
	os.exit(1)
end

-- ===== per-connection processing =====
local conns = {}
local function close_conn(fd)
	if conns[fd] then conns[fd] = nil; net.close(fd); server.conns_open = server.conns_open - 1 end
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
		elseif server.service and (v == "l" or v == "r" or v == "+++") then
			-- Every local user can reach the service socket; only the service
			-- manager may stop or restart it.
			send_line(fd, "ERR " .. v .. " is refused in service mode; use the service manager")
			log_event("error", { request = line, reason = "control command refused in service mode", peer_uid = peer_uid(fd) })
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
	local sd = net.systemd_listen_fd()
	if sd then return sd, "systemd" end
	local adopted = os.getenv("UUIDV7_LISTEN_FD")
	if adopted then return net.adopt(tonumber(adopted)), true end
	local path = server.sock_path
	assert(#path <= net.MAX_PATH, "socket path too long: " .. path)
	local dir = path:match("^(.*)[/\\][^/\\]+$")
	if not os.getenv("UUIDV7_SOCK") and not is_windows then
		-- The default socket lives in the shared /tmp: only in a verified private directory.
		local dfd = assert(core.open_private_dir(dir), "state directory " .. dir ..
			" is not a private directory owned by this user; refusing to listen there")
		ffi.C.close(dfd)
	elseif dir and dir ~= "" then
		core.ensure_dir(dir)
	end
	local fd, err = net.listen(path)
	assert(fd, err)
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
		counter = core.new_counter("auto"),   -- write-through state file, shared with the CLIs
		service = opts.service and true or false,
		requests = 0, uuids_served = 0, last_batch = 0, peak_batch = 0,
		k_same_ns = 0, k_rollback = 0, k_ts_ahead = 0, insecure_rng = 0,
		conns_open = 0, conns_served = 0, retries = 0,
		start_ns = core.get_nanotime(),
	}
	server.start_iso = (now_parts())
	server.logfh = open_logfh()
	-- An unusable state file goes to stderr (the journal, under a service manager)
	-- and the log. Touching the counter once now reports it at start rather than
	-- at the first request.
	server.counter.on_unusable = function(msg)
		io.stderr:write(msg); io.stderr:flush()   -- Windows buffers a redirected stderr
		log_event("warning", { reason = "counter state unusable; serving from this process's own counter",
			state_dir = server.counter.dir })
	end
	server.counter:locked(function() end)

	local listen_fd, adopted = make_listener()
	server.listen_fd = listen_fd
	server.owns_socket = adopted ~= "systemd"
	log_event(adopted and "restart-ready" or "start",
		{ pid = net.getpid(), version = core.VERSION, socket = server.sock_path, adopted = adopted })

	-- Readiness line: emitted to stdout the moment we're listening. Lets supervisors
	-- (and the test harness) synchronize on "ready" instead of sleeping/polling.
	-- Survives re-exec, so it also signals that a restart has finished.
	io.write("UUIDV7-LISTENING " .. server.sock_path .. "\n")
	io.flush()

	-- signals: ignore SIGPIPE; SIGINT/SIGTERM set a stop flag checked by the loop
	local stop = ffi.new("int[1]", 0)
	net.install_stop_signals(stop)

	while stop[0] == 0 do
		local fds = { listen_fd }
		for fd in pairs(conns) do fds[#fds + 1] = fd end
		local ready = net.poll(fds, 1000)
		if stop[0] ~= 0 then break end
		for fd, re in pairs(ready) do
			if fd == listen_fd then
				while true do
					local cfd = net.accept(listen_fd)
					if not cfd then break end
					conns[cfd] = { buf = "", hs = "start" }
					server.conns_open = server.conns_open + 1
					server.conns_served = server.conns_served + 1
				end
			elseif conns[fd] and bit.band(re, bit.bor(net.READ, net.HUP)) ~= 0 then
				-- read FIRST even if HUP is set: a client that shut its write side
				-- (oneshot) delivers READ+HUP together; the request is still pending.
				-- Only close once recv actually drains to EOF.
				local rb = ffi.new("char[?]", 4096)
				local nr = net.recv(fd, rb, 4096)
				if nr <= 0 then
					close_conn(fd)
				else
					local conn = conns[fd]
					conn.buf = conn.buf .. ffi.string(rb, nr)
					if process(conn, fd) == false then close_conn(fd) end
				end
			elseif conns[fd] and bit.band(re, net.ERR) ~= 0 then
				close_conn(fd)
			end
		end
	end
	shutdown("signal")
end

return M
