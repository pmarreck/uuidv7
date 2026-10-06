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
