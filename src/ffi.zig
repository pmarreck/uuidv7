//! C ABI exports for the pure core (see include/uuidv7.h). Validates pointers,
//! lengths and capacities at the boundary; the core itself never sees C types.
const core = @import("uuidv7.zig");

const OK: c_int = 0;
const ERR_NULL: c_int = -1;
const ERR_BUFFER: c_int = -2;
const ERR_INVALID: c_int = -3;
const ERR_RANGE: c_int = -4;

pub const State = extern struct { nanotime: i64, counter: u64 };

/// View a (pointer, length) pair as a slice; NULL is only valid with length 0.
fn input(ptr: ?[*]const u8, len: usize) ?[]const u8 {
	if (len == 0) return &.{};
	const p = ptr orelse return null;
	return p[0..len];
}

/// Copy `text` into the caller's buffer, honoring capacity.
fn emit(text: []const u8, out: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
	const o = out orelse return ERR_NULL;
	const l = out_len orelse return ERR_NULL;
	if (cap < text.len) return ERR_BUFFER;
	@memcpy(o[0..text.len], text);
	l.* = text.len;
	return OK;
}

export fn uuidv7_version(len: ?*usize) [*]const u8 {
	if (len) |l| l.* = core.version.len;
	return core.version.ptr;
}

export fn uuidv7_advance(stored: ?*const State, current_ns: i64, is_static: c_int, random: u64, out: ?*State, kind: ?*u8, used_random: ?*u8) c_int {
	const o = out orelse return ERR_NULL;
	const k = kind orelse return ERR_NULL;
	const u = used_random orelse return ERR_NULL;
	const prior: ?core.State = if (stored) |s| .{ .nanotime = s.nanotime, .counter = s.counter } else null;
	const step = core.advance(prior, current_ns, is_static != 0, random);
	o.* = .{ .nanotime = step.state.nanotime, .counter = step.state.counter };
	k.* = @intFromEnum(step.kind);
	u.* = @intFromBool(step.used_random);
	return OK;
}

export fn uuidv7_encode(nanotime: i64, counter: u64, out: ?[*]u8, out_len: usize) c_int {
	const o = out orelse return ERR_NULL;
	if (out_len < 16) return ERR_BUFFER;
	o[0..16].* = core.encode(nanotime, counter);
	return OK;
}

export fn uuidv7_format(bytes: ?[*]const u8, bytes_len: usize, hyphens: c_int, out: ?[*]u8, out_cap: usize, out_len: ?*usize) c_int {
	const b = bytes orelse return ERR_NULL;
	if (bytes_len != 16) return ERR_INVALID;
	var buf: [36]u8 = undefined;
	return emit(core.format(b[0..16], hyphens != 0, &buf), out, out_cap, out_len);
}

export fn uuidv7_extract(text: ?[*]const u8, text_len: usize, unit_ns: c_int, out: ?[*]u8, out_cap: usize, out_len: ?*usize) c_int {
	const t = input(text, text_len) orelse return ERR_NULL;
	var buf: [40]u8 = undefined;
	const digits = core.extract(t, if (unit_ns != 0) .ns else .ms, &buf) catch return ERR_INVALID;
	return emit(digits, out, out_cap, out_len);
}

export fn uuidv7_parse_timestamp(text: ?[*]const u8, text_len: usize, out: ?*i64) c_int {
	const o = out orelse return ERR_NULL;
	const t = input(text, text_len) orelse return ERR_NULL;
	o.* = core.parseTimestamp(t) catch |e| return switch (e) {
		error.NotANumber => ERR_INVALID,
		error.OutOfRange => ERR_RANGE,
	};
	return OK;
}

export fn uuidv7_ms_to_ns(ms: i64, out: ?*i64) c_int {
	const o = out orelse return ERR_NULL;
	o.* = core.msToNs(ms) catch return ERR_RANGE;
	return OK;
}

export fn uuidv7_filetime_to_unix_ns(filetime: u64) i64 {
	return core.filetimeToUnixNs(filetime);
}

export fn uuidv7_state_encode(state: ?*const State, out: ?[*]u8, out_cap: usize, out_len: ?*usize) c_int {
	const s = state orelse return ERR_NULL;
	var buf: [48]u8 = undefined;
	return emit(core.encodeState(.{ .nanotime = s.nanotime, .counter = s.counter }, &buf), out, out_cap, out_len);
}

export fn uuidv7_state_decode(text: ?[*]const u8, text_len: usize, out: ?*State) c_int {
	const o = out orelse return ERR_NULL;
	const t = input(text, text_len) orelse return ERR_NULL;
	const s = core.decodeState(t) orelse return ERR_INVALID;
	o.* = .{ .nanotime = s.nanotime, .counter = s.counter };
	return OK;
}

pub const Retry = extern struct { attempt: u32, waited_us: u64, delay_us: u64 };

fn toCore(r: *const Retry) core.Retry {
	return .{ .attempt = r.attempt, .waited_us = r.waited_us, .delay_us = r.delay_us };
}

export fn uuidv7_retry_init(r: ?*Retry) void {
	const d: core.Retry = .{};
	if (r) |p| p.* = .{ .attempt = d.attempt, .waited_us = d.waited_us, .delay_us = d.delay_us };
}

export fn uuidv7_retry_request(r: ?*const Retry, hyphens: c_int, out: ?[*]u8, out_cap: usize, out_len: ?*usize) c_int {
	const p = r orelse return ERR_NULL;
	var buf: [core.retry_request_max]u8 = undefined;
	return emit(core.retryRequest(toCore(p), hyphens != 0, &buf), out, out_cap, out_len);
}

export fn uuidv7_reply_served(reply: ?[*]const u8, reply_len: usize) c_int {
	const t = input(reply, reply_len) orelse return ERR_NULL;
	return @intFromBool(core.replyServed(t));
}

export fn uuidv7_retry_after_refusal(r: ?*const Retry, max_attempts: u32, timeout_us: u64, jitter: f64, next: ?*Retry, action: ?*u8, sleep_us: ?*u64) c_int {
	const p = r orelse return ERR_NULL;
	const n = next orelse return ERR_NULL;
	const a = action orelse return ERR_NULL;
	const s = sleep_us orelse return ERR_NULL;
	if (!(jitter >= 0.0 and jitter < 1.0)) return ERR_RANGE; // also rejects NaN
	switch (core.retryAfterRefusal(toCore(p), max_attempts, timeout_us, jitter)) {
		.sleep => |st| {
			n.* = .{ .attempt = st.next.attempt, .waited_us = st.next.waited_us, .delay_us = st.next.delay_us };
			s.* = st.us;
			a.* = 0;
		},
		.give_up_attempts => a.* = 1,
		.give_up_timeout => a.* = 2,
	}
	return OK;
}

export fn uuidv7_retry_attempts(no_retry: ?[*]const u8, no_retry_len: usize, retries: ?[*]const u8, retries_len: usize, out: ?*u32) c_int {
	const o = out orelse return ERR_NULL;
	const nr = input(no_retry, no_retry_len) orelse return ERR_NULL;
	const rt = input(retries, retries_len) orelse return ERR_NULL;
	o.* = core.retryAttempts(nr, rt);
	return OK;
}

export fn uuidv7_retry_timeout_us(text: ?[*]const u8, text_len: usize, out: ?*u64) c_int {
	const o = out orelse return ERR_NULL;
	o.* = core.retryTimeoutUs(input(text, text_len) orelse return ERR_NULL);
	return OK;
}
