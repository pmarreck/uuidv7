//! Unit tests for the pure Zig core. Expected values come from the LuaJIT
//! implementation (lib/uuidv7_core.lua), which is the oracle; the exhaustive
//! differential comparison lives in tests/uuidv7_differential_test.
const std = @import("std");
const core = @import("uuidv7.zig");
const testing = std.testing;

fn formatted(ns: i64, counter: u64, hyphens: bool) [36]u8 {
	var out: [36]u8 = @splat(' ');
	const b = core.encode(ns, counter);
	_ = core.format(&b, hyphens, &out);
	return out;
}

test "encode+format matches LuaJIT oracle vectors" {
	try testing.expectEqualStrings("00000000-0000-7000-8000-000000000000", &formatted(0, 0, true));
	try testing.expectEqualStrings("018bcfe5-6800-7000-9ec0-000000000005", &formatted(1700000000000000123, 5, true));
	try testing.expectEqualStrings("017f22e2-79b0-77ff-bfff-ffffffffffff", &formatted(1645557742000524287, 0x3FFFFFFFFFFFFF, true));
	try testing.expectEqualStrings("00000000-0000-7f42-8fc0-000000000001", &formatted(999999, 1, true));
	try testing.expectEqualStrings("00000000-0001-7000-8000-000000000001", &formatted(1000000, 1, true));
	try testing.expectEqualStrings("08637bd0-5af6-7bd6-9fc0-000000000000", &formatted(std.math.maxInt(i64), 0, true));
	try testing.expectEqualStrings("018bcfe568007000" ++ "9ec0000000000005", formatted(1700000000000000123, 5, false)[0..32]);
}

test "advance: new tick seeds counter from random masked to 53 bits" {
	const s = core.advance(null, 100, false, std.math.maxInt(u64));
	try testing.expectEqual(core.Kind.new, s.kind);
	try testing.expect(s.used_random);
	try testing.expectEqual(@as(i64, 100), s.state.nanotime);
	try testing.expectEqual((@as(u64, 1) << 53) - 1, s.state.counter);
}

test "advance: same ns and rollback increment without randomness" {
	const stored: core.State = .{ .nanotime = 100, .counter = 7 };
	const same = core.advance(stored, 100, false, 99);
	try testing.expectEqual(core.Kind.same_ns, same.kind);
	try testing.expect(!same.used_random);
	try testing.expectEqual(@as(u64, 8), same.state.counter);
	const back = core.advance(stored, 50, false, 99);
	try testing.expectEqual(core.Kind.rollback, back.kind);
	try testing.expectEqual(@as(i64, 100), back.state.nanotime);
	try testing.expectEqual(@as(u64, 8), back.state.counter);
}

test "advance: counter overflow borrows the next nanosecond and reseeds" {
	const stored: core.State = .{ .nanotime = 100, .counter = core.counter_mask };
	const s = core.advance(stored, 100, false, 5);
	try testing.expectEqual(core.Kind.ts_ahead, s.kind);
	try testing.expect(s.used_random);
	try testing.expectEqual(@as(i64, 101), s.state.nanotime);
	try testing.expectEqual(@as(u64, 5), s.state.counter);
}

test "advance: static timestamps never borrow time" {
	const stored: core.State = .{ .nanotime = 100, .counter = core.counter_mask };
	const wrap = core.advance(stored, 100, true, 9);
	try testing.expectEqual(core.Kind.same_ns, wrap.kind);
	try testing.expect(wrap.used_random);
	try testing.expectEqual(@as(i64, 100), wrap.state.nanotime);
	try testing.expectEqual(@as(u64, 9), wrap.state.counter);
	const earlier = core.advance(stored, 40, true, 3);
	try testing.expectEqual(core.Kind.new, earlier.kind);
	try testing.expectEqual(@as(i64, 40), earlier.state.nanotime);
}

test "extract: ms and exact ns, any case, hyphens anywhere" {
	var buf: [32]u8 = undefined;
	try testing.expectEqualStrings("1645557742000524287", try core.extract("017F22E279B077FFBFC90C9A45E78A47", .ns, &buf));
	try testing.expectEqualStrings("1645557742000", try core.extract("0-17f22e279b077ffbfc90c9a45e78a4-7", .ms, &buf));
	try testing.expectEqualStrings("281474976710656048575", try core.extract("ffffffff-ffff-7fff-bfff-ffffffffffff", .ns, &buf));
	try testing.expectEqualStrings("281474976710655", try core.extract("ffffffff-ffff-7fff-bfff-ffffffffffff", .ms, &buf));
	try testing.expectEqualStrings("1048575", try core.extract("00000000-0000-7fff-bfff-ffffffffffff", .ns, &buf));
	try testing.expectEqualStrings("0", try core.extract("00000000000070008000000000000000", .ns, &buf));
	try testing.expectError(error.InvalidUuid, core.extract("017f22e279b077ffbfc90c9a45e78a4", .ms, &buf));
	try testing.expectError(error.InvalidUuid, core.extract("017f22e279b077ffbfc90c9a45e78a4g", .ms, &buf));
	try testing.expectError(error.InvalidUuid, core.extract("", .ms, &buf));
}

test "parse_timestamp: decimal in [0, INT64_MAX], refusals otherwise" {
	try testing.expectEqual(@as(i64, 0), try core.parseTimestamp("0"));
	try testing.expectEqual(@as(i64, 0), try core.parseTimestamp("-0"));
	try testing.expectEqual(@as(i64, 7), try core.parseTimestamp("007"));
	try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try core.parseTimestamp("9223372036854775807"));
	try testing.expectError(error.OutOfRange, core.parseTimestamp("9223372036854775808"));
	try testing.expectError(error.OutOfRange, core.parseTimestamp("99999999999999999999"));
	try testing.expectError(error.OutOfRange, core.parseTimestamp("-1"));
	try testing.expectError(error.NotANumber, core.parseTimestamp("+5"));
	try testing.expectError(error.NotANumber, core.parseTimestamp(""));
	try testing.expectError(error.NotANumber, core.parseTimestamp("-"));
	try testing.expectError(error.NotANumber, core.parseTimestamp("1e5"));
	try testing.expectError(error.NotANumber, core.parseTimestamp(" 5"));
}

test "ms_to_ns refuses overflow" {
	try testing.expectEqual(@as(i64, 9223372036854000000), try core.msToNs(9223372036854));
	try testing.expectError(error.OutOfRange, core.msToNs(9223372036855));
	try testing.expectError(error.OutOfRange, core.msToNs(-1));
}

test "filetime_to_unix_ns" {
	try testing.expectEqual(@as(i64, 0), core.filetimeToUnixNs(116444736000000000));
	try testing.expectEqual(@as(i64, 100), core.filetimeToUnixNs(116444736000000001));
	try testing.expectEqual(@as(i64, 1700000000000000000), core.filetimeToUnixNs(133444736000000000));
}

test "state codec round-trips and rejects malformed text" {
	var buf: [64]u8 = undefined;
	const cases = [_]core.State{
		.{ .nanotime = 0, .counter = 0 },
		.{ .nanotime = std.math.maxInt(i64), .counter = core.counter_mask },
		.{ .nanotime = 1700000000000000123, .counter = 12345 },
	};
	for (cases) |s| {
		const text = core.encodeState(s, &buf);
		try testing.expectEqual(s, core.decodeState(text).?);
	}
	try testing.expectEqualStrings("5:6", core.encodeState(.{ .nanotime = 5, .counter = 6 }, &buf));
	try testing.expectEqual(@as(?core.State, null), core.decodeState(""));
	try testing.expectEqual(@as(?core.State, null), core.decodeState("5"));
	try testing.expectEqual(@as(?core.State, null), core.decodeState("5:"));
	try testing.expectEqual(@as(?core.State, null), core.decodeState("x5:6"));
	try testing.expectEqual(@as(?core.State, null), core.decodeState("5:6:7"));
	try testing.expectEqual(@as(?core.State, null), core.decodeState("99999999999999999999:1"));
	try testing.expectEqual(@as(?core.State, null), core.decodeState("1_0:5"));
	try testing.expectEqual(@as(?core.State, null), core.decodeState("10:5_0"));
}

test "generated sequence sorts in generation order (sorted sweep)" {
	var prng: std.Random.DefaultPrng = .init(0x5eed);
	const r = prng.random();
	var state: ?core.State = null;
	var t: i64 = 1700000000000000000;
	var prev: [32]u8 = @splat('0');
	var i: usize = 0;
	while (i < 100_000) : (i += 1) {
		// Coarse 1 ms ticks with occasional backward steps.
		t += r.intRangeAtMost(i64, -2_000_000, 300_000);
		const now = t - @mod(t, 1_000_000);
		const step = core.advance(state, now, false, r.int(u64));
		state = step.state;
		var cur: [32]u8 = undefined;
		_ = core.format(&core.encode(step.state.nanotime, step.state.counter), false, &cur);
		try testing.expect(std.mem.order(u8, &prev, &cur) == .lt);
		prev = cur;
	}
}
