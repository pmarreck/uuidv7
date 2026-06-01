-- uuidv7 core: the single source of truth for RFC 9562 UUIDv7 generation.
-- Shared by the CLI (fs/sysv counter backends) and the daemon (in-memory backend).
-- Pure LuaJIT + FFI, zero dependencies.

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
	typedef long long int64_t;
	typedef int int32_t;
	struct timeval { long tv_sec; long tv_usec; };
	struct timespec { long tv_sec; long tv_nsec; };
	int gettimeofday(struct timeval *tv, void *tz);
	int clock_gettime(int clk_id, struct timespec *tp);
	int getrandom(void *buf, size_t buflen, unsigned int flags);
	int getentropy(void *buf, size_t buflen);
	typedef int mode_t;
	typedef long off_t;
	typedef unsigned long size_t;
	typedef long ssize_t;
	int open(const char *pathname, int flags, ...);
	int close(int fd);
	ssize_t read(int fd, void *buf, size_t count);
	ssize_t write(int fd, const void *buf, size_t count);
	int unlink(const char *pathname);
	off_t lseek(int fd, off_t offset, int whence);
	int ftruncate(int fd, off_t length);
	int flock(int fd, int operation);
	int mkdir(const char *pathname, mode_t mode);
	typedef int key_t;
	int shmget(key_t key, size_t size, int shmflg);
	void *shmat(int shmid, const void *shmaddr, int shmflg);
	int shmdt(const void *shmaddr);
	long long strtoll(const char *nptr, char **endptr, int base);
	static const int O_CREAT = 0x0200;
	static const int O_RDWR = 0x0002;
	static const int LOCK_EX = 2;
	static const int LOCK_UN = 8;
	static const int SEEK_SET = 0;
	static const int CLOCK_REALTIME = 0;
	static const int IPC_CREAT = 01000;
]]

local C = ffi.C
local M = {}

M.VERSION = "0.2.0"

local is_macos = jit.os == "OSX"

-- Current time in nanoseconds since epoch (true ns on Linux and macOS >= 10.12).
local function get_nanotime()
	local ts = ffi.new("struct timespec")
	if C.clock_gettime(C.CLOCK_REALTIME, ts) == 0 then
		return ffi.cast("int64_t", ts.tv_sec) * 1000000000LL + ffi.cast("int64_t", ts.tv_nsec)
	end
	local tv = ffi.new("struct timeval")
	if C.gettimeofday(tv, nil) == 0 then
		return ffi.cast("int64_t", tv.tv_sec) * 1000000000LL + ffi.cast("int64_t", tv.tv_usec) * 1000LL
	end
	return ffi.cast("int64_t", os.time()) * 1000000000LL
end
M.get_nanotime = get_nanotime

-- Cryptographically secure random bytes (getrandom/getentropy//dev/urandom),
-- with a loud, mute-able fallback to non-secure math.random.
local function get_random_bytes(count)
	local buf = ffi.new("uint8_t[?]", count)
	if not is_macos then
		local ok = pcall(function() return C.getrandom(buf, count, 0) == count end)
		if ok then return buf end
	end
	if count <= 256 then
		local ok = pcall(function() return C.getentropy(buf, count) == 0 end)
		if ok then return buf end
	end
	local f = io.open("/dev/urandom", "rb")
	if f then
		local data = f:read(count)
		f:close()
		if data and #data == count then ffi.copy(buf, data, count); return buf end
	end
	if not os.getenv("UUIDV7_SILENCE_INSECURE_RANDOM") then
		io.stderr:write("\27[31muuidv7 WARNING: no secure RNG available (getrandom/getentropy//dev/urandom all failed); " ..
			"falling back to math.random, which is NOT cryptographically secure. " ..
			"Set UUIDV7_SILENCE_INSECURE_RANDOM=1 to mute this warning.\27[0m\n")
	end
	math.randomseed(tonumber(get_nanotime()))
	for i = 0, count - 1 do buf[i] = math.random(0, 255) end
	return buf
end
M.get_random_bytes = get_random_bytes

local COUNTER_MASK = bit.lshift(1ULL, 54) - 1ULL
local COUNTER_INIT_MASK = bit.rshift(COUNTER_MASK, 1)
local NS_PER_MS = 1000000LL

local function num_to_dec(v) return (tostring(v):gsub("[uUlL]+$", "")) end

local function parse_static(s)
	if type(s) ~= "string" or not s:match("^%-?%d+$") then return nil end
	return C.strtoll(s, nil, 10)
end
M.parse_static = parse_static

local function random_counter_init()
	local b = get_random_bytes(8)
	local v = 0ULL
	for i = 0, 7 do v = bit.bor(bit.lshift(v, 8), ffi.cast("uint64_t", b[i])) end
	return bit.band(v, COUNTER_INIT_MASK)
end

-- Pure state transition. Returns (effective_nanotime:int64, counter:uint64, kind:string).
-- kind in {"new","same_ns","rollback","ts_ahead"} for stats.
local function advance(stored_nt, stored_ctr, current_nt, is_static)
	if is_static then
		if stored_nt ~= nil and stored_nt == current_nt then
			local ctr = bit.band(stored_ctr + 1ULL, COUNTER_MASK)
			if ctr == 0ULL then ctr = random_counter_init() end
			return current_nt, ctr, "same_ns"
		end
		return current_nt, random_counter_init(), "new"
	end
	if stored_nt == nil or current_nt > stored_nt then
		return current_nt, random_counter_init(), "new"
	end
	local kind = (current_nt == stored_nt) and "same_ns" or "rollback"
	local eff = stored_nt
	local ctr = bit.band(stored_ctr + 1ULL, COUNTER_MASK)
	if ctr == 0ULL then
		eff = stored_nt + 1LL
		ctr = random_counter_init()
		kind = "ts_ahead"
	end
	return eff, ctr, kind
end
M.advance = advance

-- ===== Counter backends =====

-- In-memory (daemon single-process): fastest, no I/O, strictly monotonic.
local MemoryCounter = {}
MemoryCounter.__index = MemoryCounter
function MemoryCounter:new() return setmetatable({ _nt = nil, _ctr = nil }, self) end
function MemoryCounter:get_next(current_nt, is_static)
	local eff, ctr, kind = advance(self._nt, self._ctr, current_nt, is_static)
	self._nt, self._ctr = eff, ctr
	return eff, ctr, kind
end

-- Filesystem (macOS CLI default): flock'd file under $TMPDIR, atomic cross-process RMW.
local FsCounter = {}
FsCounter.__index = FsCounter
function FsCounter:new()
	local tmp = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
	return setmetatable({ filepath = tmp .. "/uuidv7-sequence", _nt = nil, _ctr = nil }, self)
end
function FsCounter:get_next(current_nt, is_static)
	local fd = C.open(self.filepath, bit.bor(C.O_CREAT, C.O_RDWR), ffi.new("int", 438))
	if fd < 0 then
		self._nt, self._ctr = advance(self._nt, self._ctr, current_nt, is_static)
		return self._nt, self._ctr, "new"
	end
	C.flock(fd, C.LOCK_EX)
	C.lseek(fd, 0, C.SEEK_SET)
	local buf = ffi.new("char[?]", 96)
	local n = C.read(fd, buf, 95)
	local stored_nt, stored_ctr
	if n > 0 then
		local s_nt, s_ctr = ffi.string(buf, n):match("(%-?%d+):(%d+)")
		if s_nt and s_ctr then
			stored_nt = C.strtoll(s_nt, nil, 10)
			stored_ctr = ffi.cast("uint64_t", C.strtoll(s_ctr, nil, 10))
		end
	end
	local eff, ctr, kind = advance(stored_nt, stored_ctr, current_nt, is_static)
	local out = num_to_dec(eff) .. ":" .. num_to_dec(ctr)
	C.lseek(fd, 0, C.SEEK_SET)
	C.ftruncate(fd, 0)
	C.write(fd, out, #out)
	C.flock(fd, C.LOCK_UN)
	C.close(fd)
	return eff, ctr, kind
end

-- System V shared memory (Linux CLI default). Best-effort RMW (no semaphore).
local SysVCounter = {}
SysVCounter.__index = SysVCounter
function SysVCounter:new() return setmetatable({ key = 0x75756964, _nt = nil, _ctr = nil }, self) end
function SysVCounter:get_next(current_nt, is_static)
	local shmid = C.shmget(self.key, 16, bit.bor(C.IPC_CREAT, 438))
	if shmid == -1 then
		self._nt, self._ctr = advance(self._nt, self._ctr, current_nt, is_static)
		return self._nt, self._ctr, "new"
	end
	local ptr = C.shmat(shmid, nil, 0)
	if ffi.cast("intptr_t", ptr) == ffi.cast("intptr_t", -1) then
		self._nt, self._ctr = advance(self._nt, self._ctr, current_nt, is_static)
		return self._nt, self._ctr, "new"
	end
	local nt_ptr = ffi.cast("int64_t*", ptr)
	local ctr_ptr = ffi.cast("uint64_t*", ffi.cast("char*", ptr) + 8)
	local stored_nt, stored_ctr
	if nt_ptr[0] ~= 0LL then stored_nt = nt_ptr[0]; stored_ctr = ctr_ptr[0] end
	local eff, ctr, kind = advance(stored_nt, stored_ctr, current_nt, is_static)
	nt_ptr[0] = eff
	ctr_ptr[0] = ctr
	C.shmdt(ptr)
	return eff, ctr, kind
end

function M.new_counter(backend)
	if backend == "auto" or backend == nil then
		backend = is_macos and "fs" or "sysv"
	end
	if backend == "memory" then return MemoryCounter:new()
	elseif backend == "fs" then return FsCounter:new()
	elseif backend == "sysv" then return SysVCounter:new()
	end
	error("uuidv7_core: unknown counter backend " .. tostring(backend))
end

-- Build the 16 UUID bytes for one value. Returns (bytes, kind).
local function generate_bytes(counter, static_nanotime)
	local is_static = static_nanotime ~= nil
	local current = static_nanotime or get_nanotime()
	local eff, ctr, kind = counter:get_next(current, is_static)
	local ms = ffi.cast("uint64_t", eff / NS_PER_MS)
	local ns = tonumber(eff % NS_PER_MS)
	local ns_hi12 = bit.band(bit.rshift(ns, 8), 0xFFF)
	local ns_lo8 = bit.band(ns, 0xFF)
	local rand_b = bit.bor(bit.lshift(ffi.cast("uint64_t", ns_lo8), 54), bit.band(ctr, COUNTER_MASK))
	local u = {}
	u[1] = tonumber(bit.band(bit.rshift(ms, 40), 0xFF))
	u[2] = tonumber(bit.band(bit.rshift(ms, 32), 0xFF))
	u[3] = tonumber(bit.band(bit.rshift(ms, 24), 0xFF))
	u[4] = tonumber(bit.band(bit.rshift(ms, 16), 0xFF))
	u[5] = tonumber(bit.band(bit.rshift(ms, 8), 0xFF))
	u[6] = tonumber(bit.band(ms, 0xFF))
	u[7] = bit.bor(0x70, bit.rshift(ns_hi12, 8))
	u[8] = bit.band(ns_hi12, 0xFF)
	u[9]  = tonumber(bit.bor(0x80, bit.band(bit.rshift(rand_b, 56), 0x3F)))
	u[10] = tonumber(bit.band(bit.rshift(rand_b, 48), 0xFF))
	u[11] = tonumber(bit.band(bit.rshift(rand_b, 40), 0xFF))
	u[12] = tonumber(bit.band(bit.rshift(rand_b, 32), 0xFF))
	u[13] = tonumber(bit.band(bit.rshift(rand_b, 24), 0xFF))
	u[14] = tonumber(bit.band(bit.rshift(rand_b, 16), 0xFF))
	u[15] = tonumber(bit.band(bit.rshift(rand_b, 8), 0xFF))
	u[16] = tonumber(bit.band(rand_b, 0xFF))
	return u, kind
end
M.generate_bytes = generate_bytes

local function format_uuid(b, with_hyphens)
	local hex = {}
	for i = 1, 16 do hex[i] = string.format("%02x", b[i]) end
	if with_hyphens then
		return table.concat(hex, "", 1, 4) .. "-" .. table.concat(hex, "", 5, 6) .. "-" ..
		       table.concat(hex, "", 7, 8) .. "-" .. table.concat(hex, "", 9, 10) .. "-" ..
		       table.concat(hex, "", 11, 16)
	end
	return table.concat(hex)
end
M.format_uuid = format_uuid

-- Recover the original epoch timestamp encoded in a UUIDv7 produced by this tool.
-- The inverse of generate_bytes' time encoding. `unit` is "ms" (the 48-bit
-- unix_ts_ms field) or "ns" (full epoch nanoseconds, including the sub-ms bits we
-- pack into rand_a/rand_b). The counter and any randomization live in bits the
-- timestamp does not occupy, so this is exact regardless of counter increments.
-- Accepts the UUID with or without hyphens, in any capitalization.
-- Returns a decimal string, or nil plus an error message on malformed input.
local function extract_timestamp(uuid, unit)
	unit = unit or "ms"
	if unit ~= "ms" and unit ~= "ns" then return nil, "unit must be 'ms' or 'ns'" end
	if type(uuid) ~= "string" then return nil, "uuid must be a string" end
	local hex = uuid:gsub("%-", ""):lower()
	if #hex ~= 32 or hex:match("[^0-9a-f]") then
		return nil, "expected 32 hex digits (with or without hyphens), got: " .. uuid
	end
	local b = {}
	for i = 0, 15 do b[i + 1] = tonumber(hex:sub(i * 2 + 1, i * 2 + 2), 16) end
	-- bytes 1-6: unix_ts_ms, big-endian 48-bit.
	local ms = 0ULL
	for i = 1, 6 do ms = bit.bor(bit.lshift(ms, 8), ffi.cast("uint64_t", b[i])) end
	if unit == "ms" then return num_to_dec(ms) end
	-- Reassemble the 20-bit sub-ms nanosecond: hi12 = byte7 low nibble + byte8;
	-- lo8 = top 6 bits of byte9 (after the variant) + top 2 bits of byte10.
	local ns_hi12 = bit.bor(bit.lshift(bit.band(b[7], 0x0F), 8), b[8])
	local ns_lo8  = bit.bor(bit.lshift(bit.band(b[9], 0x3F), 2), bit.rshift(b[10], 6))
	local ns_in_ms = bit.bor(bit.lshift(ns_hi12, 8), ns_lo8)
	local ns = ms * ffi.cast("uint64_t", NS_PER_MS) + ffi.cast("uint64_t", ns_in_ms)
	return num_to_dec(ns)
end
M.extract_timestamp = extract_timestamp

-- High-level: generate `count` formatted UUID strings. Returns (lines, kind_counts).
-- opts = { time=int64|nil, hyphens=bool, count=int }
function M.generate(counter, opts)
	opts = opts or {}
	local count = opts.count or 1
	local lines = {}
	local kinds = { new = 0, same_ns = 0, rollback = 0, ts_ahead = 0 }
	for i = 1, count do
		local b, kind = generate_bytes(counter, opts.time)
		lines[i] = format_uuid(b, opts.hyphens)
		kinds[kind] = (kinds[kind] or 0) + 1
	end
	return lines, kinds
end

return M
