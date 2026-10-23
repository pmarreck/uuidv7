//! Pure UUIDv7 core (RFC 9562), a port of lib/uuidv7_core.lua. No I/O, no clock,
//! no allocation: callers supply the time, the random seed and the stored counter
//! state, so the same inputs always give the same bytes (the property the LuaJIT
//! differential oracle checks).
//!
//! Layout: 48-bit unix_ts_ms | ver 7 | 12 high bits of the 20-bit sub-millisecond
//! nanosecond | variant 10 | 8 low sub-ms bits | 54-bit monotonic counter.
const std = @import("std");

pub const version = "0.2.0";
pub const ns_per_ms: i64 = 1_000_000;
pub const counter_mask: u64 = (@as(u64, 1) << 54) - 1;
/// Fresh counters start in the lower half so ~2^53 increments fit before overflow.
pub const counter_init_mask: u64 = counter_mask >> 1;
/// Largest millisecond value whose nanosecond product fits in i64.
pub const max_ms: i64 = @divTrunc(std.math.maxInt(i64), ns_per_ms);
const filetime_unix_epoch: i64 = 116444736000000000;

pub const Kind = enum(u8) { new = 1, same_ns = 2, rollback = 3, ts_ahead = 4 };

pub const State = struct { nanotime: i64, counter: u64 };

pub const Step = struct { state: State, kind: Kind, used_random: bool };

/// Monotonic counter state transition (RFC 9562 Method 3 plus a 54-bit counter):
/// a newer tick reseeds the counter from `random`; the same tick or a clock that
/// stepped backward freezes time and increments; counter overflow borrows the
/// next nanosecond. Explicit (static) timestamps never borrow time. `random` is
/// consumed only when `used_random` is set, mirroring the Lua oracle's lazy draw.
pub fn advance(stored: ?State, current_ns: i64, is_static: bool, random: u64) Step {
	const seed = random & counter_init_mask;
	if (is_static) {
		if (stored) |s| if (s.nanotime == current_ns) {
			const ctr = (s.counter +% 1) & counter_mask;
			if (ctr == 0) return .{ .state = .{ .nanotime = current_ns, .counter = seed }, .kind = .same_ns, .used_random = true };
			return .{ .state = .{ .nanotime = current_ns, .counter = ctr }, .kind = .same_ns, .used_random = false };
		};
		return .{ .state = .{ .nanotime = current_ns, .counter = seed }, .kind = .new, .used_random = true };
	}
	const s = stored orelse return .{ .state = .{ .nanotime = current_ns, .counter = seed }, .kind = .new, .used_random = true };
	if (current_ns > s.nanotime) return .{ .state = .{ .nanotime = current_ns, .counter = seed }, .kind = .new, .used_random = true };
	const kind: Kind = if (current_ns == s.nanotime) .same_ns else .rollback;
	const ctr = (s.counter +% 1) & counter_mask;
	if (ctr == 0) return .{ .state = .{ .nanotime = s.nanotime +% 1, .counter = seed }, .kind = .ts_ahead, .used_random = true };
	return .{ .state = .{ .nanotime = s.nanotime, .counter = ctr }, .kind = kind, .used_random = false };
}

/// RFC 9562 byte layout for an effective epoch nanosecond (domain: 0..INT64_MAX)
/// and a 54-bit counter.
pub fn encode(ns: i64, counter: u64) [16]u8 {
	const ms: u64 = @bitCast(@divTrunc(ns, ns_per_ms));
	const sub: u64 = @bitCast(@rem(ns, ns_per_ms));
	const hi12 = (sub >> 8) & 0xFFF;
	const lo8 = sub & 0xFF;
	const rand_b = (lo8 << 54) | (counter & counter_mask);
	var u: [16]u8 = undefined;
	inline for (0..6) |i| u[i] = @truncate(ms >> @intCast(40 - 8 * i));
	u[6] = @intCast(0x70 | (hi12 >> 8));
	u[7] = @truncate(hi12);
	u[8] = @intCast(0x80 | ((rand_b >> 56) & 0x3F));
	inline for (9..16) |i| u[i] = @truncate(rand_b >> @intCast(8 * (15 - i)));
	return u;
}

/// Lowercase hex, 8-4-4-4-12 when `hyphens`. Writes 36 or 32 bytes into `out`
/// (which must hold them) and returns the written slice.
pub fn format(bytes: *const [16]u8, hyphens: bool, out: []u8) []u8 {
	const hex = "0123456789abcdef";
	var o: usize = 0;
	for (bytes, 0..) |b, i| {
		if (hyphens and (i == 4 or i == 6 or i == 8 or i == 10)) {
			out[o] = '-';
			o += 1;
		}
		out[o] = hex[b >> 4];
		out[o + 1] = hex[b & 0xF];
		o += 2;
	}
	return out[0..o];
}

pub const Unit = enum(u8) { ms = 0, ns = 1 };

/// Recover the encoded epoch time as a decimal string. Accepts any capitalization
/// with hyphens anywhere (all are ignored), like the Lua oracle. The nanosecond
/// value can exceed 2^64 (max 48-bit ms), so it is computed in u128.
/// `out` needs at least 21 bytes.
pub fn extract(text: []const u8, unit: Unit, out: []u8) error{InvalidUuid}![]u8 {
	var b: [16]u8 = undefined;
	var nibbles: usize = 0;
	for (text) |c| {
		if (c == '-') continue;
		const v = std.fmt.charToDigit(c, 16) catch return error.InvalidUuid;
		if (nibbles == 32) return error.InvalidUuid;
		if (nibbles % 2 == 0) b[nibbles / 2] = @as(u8, v) << 4 else b[nibbles / 2] |= v;
		nibbles += 1;
	}
	if (nibbles != 32) return error.InvalidUuid;
	var ms: u128 = 0;
	for (b[0..6]) |x| ms = (ms << 8) | x;
	const value: u128 = switch (unit) {
		.ms => ms,
		.ns => blk: {
			const hi12: u128 = (@as(u128, b[6] & 0x0F) << 8) | b[7];
			const lo8: u128 = (@as(u128, b[8] & 0x3F) << 2) | (b[9] >> 6);
			break :blk ms * @as(u128, ns_per_ms) + ((hi12 << 8) | lo8);
		},
	};
	return std.fmt.bufPrint(out, "{d}", .{value}) catch unreachable;
}

pub const ParseError = error{ NotANumber, OutOfRange };

/// Explicit epoch-nanosecond timestamp: a decimal integer (optional leading '-')
/// in [0, INT64_MAX]. Other integers are OutOfRange; anything else NotANumber.
pub fn parseTimestamp(text: []const u8) ParseError!i64 {
	const neg = text.len > 0 and text[0] == '-';
	const digits = text[@intFromBool(neg)..];
	if (digits.len == 0) return error.NotANumber;
	for (digits) |c| if (c < '0' or c > '9') return error.NotANumber;
	var v: i64 = 0;
	for (digits) |c| {
		v = std.math.mul(i64, v, 10) catch return error.OutOfRange;
		v = std.math.add(i64, v, c - '0') catch return error.OutOfRange;
	}
	if (neg and v != 0) return error.OutOfRange;
	return v;
}

/// Milliseconds to nanoseconds, refusing negative values and overflow.
pub fn msToNs(ms: i64) error{OutOfRange}!i64 {
	if (ms < 0 or ms > max_ms) return error.OutOfRange;
	return ms * ns_per_ms;
}

/// Windows FILETIME (100 ns ticks since 1601-01-01 UTC) to Unix epoch nanoseconds.
pub fn filetimeToUnixNs(filetime: u64) i64 {
	const ft: i64 = @bitCast(filetime);
	return (ft -% filetime_unix_epoch) *% 100;
}

/// Counter-state file text: "<nanotime>:<counter>" in decimal. `out` needs 41 bytes.
pub fn encodeState(s: State, out: []u8) []u8 {
	return std.fmt.bufPrint(out, "{d}:{d}", .{ s.nanotime, s.counter }) catch unreachable;
}

/// Strict inverse of encodeState; any other text (corrupt or foreign) is null,
/// which callers treat as "no stored state".
pub fn decodeState(text: []const u8) ?State {
	const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
	const nt_text = text[0..colon];
	const ctr_text = text[colon + 1 ..];
	// Plain decimal only: std.fmt.parseInt would also take '+' and '_' separators.
	if (!isDecimal(if (nt_text.len > 0 and nt_text[0] == '-') nt_text[1..] else nt_text)) return null;
	if (!isDecimal(ctr_text)) return null;
	const nt = std.fmt.parseInt(i64, nt_text, 10) catch return null;
	const ctr = std.fmt.parseInt(u64, ctr_text, 10) catch return null;
	return .{ .nanotime = nt, .counter = ctr };
}

fn isDecimal(text: []const u8) bool {
	if (text.len == 0) return false;
	for (text) |c| if (c < '0' or c > '9') return false;
	return true;
}

// ---- daemon client retry policy (port of try_daemon in lib/uuidv7_client.lua) ----
// A reachable daemon owns the live stream, so a client that gets an empty or ERR
// reply retries the daemon with bounded, growing backoff and never generates
// locally. The caller does the socket I/O, the sleeping and the jitter draw.

pub const backoff_base_us: u64 = 50;
pub const default_retry_attempts: u32 = 20;
pub const default_retry_timeout_us: u64 = 2000;
/// Longest request line: "-R" ++ u32 ++ "W" ++ u64.
pub const retry_request_max = 2 + 10 + 1 + 20;

/// Position in a retry sequence: the attempt about to be sent (1-based), the
/// backoff already waited, and the next backoff delay.
pub const Retry = struct { attempt: u32 = 1, waited_us: u64 = 0, delay_us: u64 = backoff_base_us };

pub const RetryStep = union(enum) {
	sleep: struct { us: u64, next: Retry },
	give_up_attempts,
	give_up_timeout,
};

/// Protocol line for one attempt: "" or "-" (hyphenated) first; retries append
/// "R<attempt>W<waited_us>" so the daemon can log and count them.
pub fn retryRequest(r: Retry, hyphens: bool, out: []u8) []u8 {
	const tok: []const u8 = if (hyphens) "-" else "";
	if (r.attempt <= 1) return std.fmt.bufPrint(out, "{s}", .{tok}) catch unreachable;
	return std.fmt.bufPrint(out, "{s}R{d}W{d}", .{ tok, r.attempt, r.waited_us }) catch unreachable;
}

/// A daemon served the request when its reply is non-empty and not an ERR line.
pub fn replyServed(resp: []const u8) bool {
	return resp.len > 0 and !std.mem.startsWith(u8, resp, "ERR");
}

/// Next move after a refused attempt: give up at the attempt cap, then when the
/// next sleep would exceed the total wait budget; otherwise sleep and grow the
/// delay by floor(delay * (1.5 + jitter * 0.1)) with `jitter` in [0, 1).
pub fn retryAfterRefusal(r: Retry, max_attempts: u32, timeout_us: u64, jitter: f64) RetryStep {
	if (r.attempt >= max_attempts) return .give_up_attempts;
	if (r.waited_us +| r.delay_us > timeout_us) return .give_up_timeout;
	const grown = @floor(@as(f64, @floatFromInt(r.delay_us)) * (1.5 + jitter * 0.1));
	const max_f: f64 = @floatFromInt(std.math.maxInt(u64));
	const next_delay: u64 = if (grown >= max_f) std.math.maxInt(u64) else @intFromFloat(grown);
	return .{ .sleep = .{ .us = r.delay_us, .next = .{
		.attempt = r.attempt + 1,
		.waited_us = r.waited_us + r.delay_us,
		.delay_us = next_delay,
	} } };
}

/// Attempt cap from UUIDV7_DAEMON_NO_RETRY ("1"/"true" in any case forces one
/// try) and UUIDV7_DAEMON_RETRIES (a decimal integer >= 1, saturating).
/// Anything else gives the default. The Lua oracle's tonumber also accepts hex,
/// exponents and fractions; this port takes plain decimal only.
pub fn retryAttempts(no_retry: ?[]const u8, retries: ?[]const u8) u32 {
	if (no_retry) |v| if (std.ascii.eqlIgnoreCase(v, "1") or std.ascii.eqlIgnoreCase(v, "true")) return 1;
	const n = parseDecimalSaturating(retries orelse return default_retry_attempts) orelse return default_retry_attempts;
	if (n < 1) return default_retry_attempts;
	return std.math.cast(u32, n) orelse std.math.maxInt(u32);
}

/// Total backoff budget from UUIDV7_DAEMON_RETRY_TIMEOUT_US (decimal >= 0, saturating).
pub fn retryTimeoutUs(text: ?[]const u8) u64 {
	return parseDecimalSaturating(text orelse return default_retry_timeout_us) orelse default_retry_timeout_us;
}

fn parseDecimalSaturating(text: []const u8) ?u64 {
	if (!isDecimal(text)) return null;
	return std.fmt.parseInt(u64, text, 10) catch std.math.maxInt(u64);
}

// ---- refused system socket ----
// When the installed system service's socket file exists but connections are
// refused (the service crashed and left it), the service manager restarts the
// service. Clients count consecutive refusals in the per-user state directory:
// the first `service_restarts` fail with a try-again message, later ones are an
// error. The caller reads and writes the count file.

pub const service_restarts: u32 = 3;

pub const ServiceRefusal = enum { try_again, give_up };

/// The refusal count to store and what to report, from the stored count text
/// (plain decimal; anything else counts as no prior refusals). Saturating.
pub fn serviceRefusal(prior: []const u8) struct { count: u32, action: ServiceRefusal } {
	const p: u32 = if (parseDecimalSaturating(prior)) |n| (std.math.cast(u32, n) orelse std.math.maxInt(u32)) else 0;
	const count = p +| 1;
	return .{ .count = count, .action = if (count <= service_restarts) .try_again else .give_up };
}
