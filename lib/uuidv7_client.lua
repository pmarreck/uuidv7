-- uuidv7 UDS client: used by the CLI to transparently use a running daemon, and by
-- the test harness to drive it. All socket and sleep calls go through uuidv7_net.

local ffi = require("ffi")
local core = require("uuidv7_core")   -- clock for jitter seed
local net = require("uuidv7_net")     -- sockets + sleep, POSIX or Winsock

local M = {}

-- $UUIDV7_SOCK, else uuidv7.sock in the per-user state directory (see core.state_dir).
local function default_path()
	if os.getenv("UUIDV7_SOCK") then return os.getenv("UUIDV7_SOCK") end
	return core.state_file("uuidv7.sock") or ""
end
M.default_path = default_path

local Conn = {}
Conn.__index = Conn

function M.open(path)
	path = path or default_path()
	if #path > net.MAX_PATH then return nil, "socket path too long" end
	local fd, err = net.connect(path)
	if not fd then return nil, err end
	return setmetatable({ fd = fd, buf = "" }, Conn)
end

function Conn:send_raw(s)
	local p = ffi.cast("const char*", s)
	local total, sent = #s, 0
	while sent < total do
		local n = net.send(self.fd, p + sent, total - sent)
		if n <= 0 then return false end
		sent = sent + n
	end
	return true
end

function Conn:send(line) return self:send_raw(line .. "\n") end

local function fill(self)
	local rb = ffi.new("char[?]", 4096)
	local n = net.recv(self.fd, rb, 4096)
	if n <= 0 then return false end
	self.buf = self.buf .. ffi.string(rb, n)
	return true
end

function Conn:recv_line()
	while true do
		local nl = self.buf:find("\n", 1, true)
		if nl then
			local line = self.buf:sub(1, nl - 1)
			self.buf = self.buf:sub(nl + 1)
			return line
		end
		if not fill(self) then
			if #self.buf > 0 then local l = self.buf; self.buf = ""; return l end
			return nil
		end
	end
end

function Conn:recv_bytes(n)
	while #self.buf < n do if not fill(self) then break end end
	local out = self.buf:sub(1, n)
	self.buf = self.buf:sub(n + 1)
	return out
end

function Conn:shutdown_wr() net.shutdown_write(self.fd) end

function Conn:recv_all()
	while fill(self) do end
	local out = self.buf
	self.buf = ""
	return out
end

function Conn:close() if self.fd then net.close(self.fd); self.fd = nil end end

-- One request, full response (client signals EOF so the server returns and closes).
function M.oneshot(path, line)
	local c, err = M.open(path)
	if not c then return nil, err end
	c:send(line)
	c:shutdown_wr()
	local resp = c:recv_all()
	c:close()
	return resp
end

-- ===== daemon retry policy =====
-- A reachable daemon owns the live stream. If it momentarily won't serve, we retry
-- IT (never generate locally — that uses the separate locked-file counter and could break
-- monotonicity). Backoff starts real small and grows ~1.5x with a little jitter, bounded
-- by BOTH an attempt cap and a total wait timeout, after which we error loudly.
local BACKOFF_BASE_US    = 50      -- first backoff: 50 microseconds (real small)
local DEFAULT_ATTEMPTS   = 20      -- hard cap on tries (incl. the first)
local DEFAULT_TIMEOUT_US = 2000    -- total backoff-wait budget (2 ms) before erroring

-- Seed jitter (non-crypto; quality is irrelevant, we just want de-synchronized retries).
math.randomseed(tonumber(core.get_nanotime() % 2147483647LL))

local function truthy(v) v = v and v:lower(); return v == "1" or v == "true" end

-- Max attempts. UUIDV7_DAEMON_NO_RETRY forces a single try ("error instead of retry").
function M.retry_attempts()
	if truthy(os.getenv("UUIDV7_DAEMON_NO_RETRY")) then return 1 end
	local n = tonumber(os.getenv("UUIDV7_DAEMON_RETRIES") or "")
	return (n and n >= 1) and math.floor(n) or DEFAULT_ATTEMPTS
end

-- Total microseconds of backoff wait permitted before giving up with a timeout error.
function M.retry_timeout_us()
	local n = tonumber(os.getenv("UUIDV7_DAEMON_RETRY_TIMEOUT_US") or "")
	return (n and n >= 0) and math.floor(n) or DEFAULT_TIMEOUT_US
end

-- Sleep for `us` microseconds (sub-millisecond capable).
M.sleep_us = net.sleep_us

local function unserved_msg(cause, attempt, waited_us, timeout_us, last)
	local why = (last and last ~= "") and (" (last reply: " .. (last:gsub("%s+$", "")) .. ")") or ""
	local detail
	if cause == "timeout" then
		detail = "within the " .. timeout_us .. "us retry timeout (" .. attempt ..
			" attempts, waited " .. waited_us .. "us)"
	elseif attempt <= 1 then
		detail = "and retries are disabled (UUIDV7_DAEMON_NO_RETRY)"
	else
		detail = "after " .. attempt .. " attempts (waited " .. waited_us .. "us)"
	end
	return "daemon at " .. default_path() .. " is reachable but would not serve a UUID " ..
		detail .. why .. "; refusing to silently generate locally (that could break monotonicity). " ..
		"Retry, raise UUIDV7_DAEMON_RETRY_TIMEOUT_US, or stop the daemon with `uuidv7 --api +++`."
end

-- Decide how to satisfy a LIVE generation request. Pure except for the transport
-- (M.oneshot) and the clock (sleep); returns an action so the side-effecting wrapper
-- stays tiny/testable. opts (for tests) may override: attempts, timeout_us, sleep, rand,
-- backoff_us. Returns:
--   "pass"        -> no daemon reachable, or a static/unknown-arg request: the
--                    standalone CLI should generate locally (this is NOT a fallback).
--   "emit", resp  -> a daemon served this response; print it verbatim.
--   "error", msg  -> a daemon answered the socket but would not serve a UUID within the
--                    retry budget. The caller must NOT generate locally: the daemon
--                    dispenses from its in-memory counter while local generation uses the
--                    separate locked-file counter, so a silent fallback could emit a UUID that
--                    sorts out of order against the daemon's stream. Fail loud instead.
function M.try_daemon(args, opts)
	opts = opts or {}
	if os.getenv("UUIDV7_NO_DAEMON") then return "pass" end
	local hyphen, static = false, false
	for _, a in ipairs(args) do
		if a == "-" or a == "--hyphen" or a == "--hyphens" then hyphen = true
		elseif a:match("^%-?%d+$") then static = true
		else return "pass" end   -- unknown flag => let the local CLI handle it
	end
	if static then return "pass" end   -- explicit time stays local (reproducible)
	local base_tok     = hyphen and "-" or ""
	local attempts_cap = opts.attempts   or M.retry_attempts()
	local timeout_us   = opts.timeout_us or M.retry_timeout_us()
	local sleep        = opts.sleep      or M.sleep_us
	local rand         = opts.rand       or math.random
	local delay        = opts.backoff_us or BACKOFF_BASE_US
	local waited_us, attempt, last = 0, 0, nil
	while true do
		attempt = attempt + 1
		-- On a retry, tell the daemon the attempt # and total wait so it logs them.
		local line = (attempt > 1) and (base_tok .. "R" .. attempt .. "W" .. waited_us) or base_tok
		local resp = M.oneshot(nil, line)
		if resp == nil then
			-- Couldn't connect: no live daemon (or a stale socket). Local generation is
			-- the correct standalone behavior — there is no live stream to violate.
			return "pass"
		end
		if resp ~= "" and not resp:match("^ERR") then
			return "emit", resp
		end
		last = resp   -- reachable but empty/ERR: retry the DAEMON, never go local
		if attempt >= attempts_cap then
			return "error", unserved_msg("attempts", attempt, waited_us, timeout_us, last)
		end
		if waited_us + delay > timeout_us then
			return "error", unserved_msg("timeout", attempt, waited_us, timeout_us, last)
		end
		sleep(delay)
		waited_us = waited_us + delay
		delay = math.floor(delay * (1.5 + rand() * 0.1))   -- ~1.5x growth + <0.1 jitter
	end
end

-- CLI fast-path: route LIVE generation to a running daemon if present. Returns true
-- if it handled the request (printed a daemon-served UUID); false to let the local
-- CLI generate. Exits non-zero if a reachable daemon refuses to serve (no silent
-- fallback — see M.try_daemon).
function M.maybe_handle(args)
	local action, payload = M.try_daemon(args)
	if action == "emit" then io.write(payload); return true end
	if action == "error" then
		io.stderr:write("uuidv7: " .. payload .. "\n")
		os.exit(1)
	end
	return false   -- "pass": no daemon involved, generate locally
end

return M
