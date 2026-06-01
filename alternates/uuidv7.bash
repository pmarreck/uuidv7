#!/usr/bin/env bash
# Reference (alternate) UUIDv7 generator in pure Bash — NOT the primary implementation
# (see ../bin/uuidv7, the LuaJIT version with true nanosecond precision + a 54-bit
# monotonic counter). Kept for lineage/comparison. This version: millisecond timestamp
# + an in-process 12-bit monotonic sequence (RFC 9562 Method 1) in rand_a, random rand_b.
# Works on both Linux and macOS.

# %N (sub-second) requires GNU date; BSD/macOS `date` lacks it, so prefer `gdate`.
# Detected once when sourced/executed (cheap: avoids per-call `date --version`).
if [[ "$(date +%N 2>/dev/null)" == *[0-9]* && "$(date +%N 2>/dev/null)" != *N* ]]; then
	_UUIDV7_DATE=date
elif command -v gdate >/dev/null 2>&1; then
	_UUIDV7_DATE=gdate
else
	_UUIDV7_DATE=date   # last resort; %3N may stay literal on BSD date (degraded)
fi

_uuidv7_rand16() { printf '%d' "0x$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"; }  # 0..65535

_UUIDV7_LAST_MS=""
_UUIDV7_SEQ=0

uuidv7() {
	local now_ms seq t_hex rb v6 v7 v8 rest hex
	now_ms=$("$_UUIDV7_DATE" +%s%3N)
	if [[ "$now_ms" != "$_UUIDV7_LAST_MS" ]]; then
		_UUIDV7_SEQ=$(( $(_uuidv7_rand16) & 0x7FF ))   # new ms: seed in lower half (guard bit)
		_UUIDV7_LAST_MS="$now_ms"
	else
		_UUIDV7_SEQ=$(( (_UUIDV7_SEQ + 1) & 0xFFF ))   # same ms: 12-bit counter ++
	fi
	seq=$_UUIDV7_SEQ
	t_hex=$(printf '%012x' "$now_ms")
	rb=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')   # 8 bytes for rand_b
	v6=$(printf '%02x' $(( 0x70 | ((seq >> 8) & 0x0F) )))   # ver=0111 + rand_a[11:8]
	v7=$(printf '%02x' $(( seq & 0xFF )))                   # rand_a[7:0]
	v8=$(printf '%02x' $(( 0x80 | (0x${rb:0:2} & 0x3F) ))) # var=10 + 6 random bits
	rest="${rb:2:14}"                                       # remaining 7 random bytes
	hex="${t_hex}${v6}${v7}${v8}${rest}"
	case "$1" in
		--hyphen|--hyphens|-)
			printf '%s-%s-%s-%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}" ;;
		*)
			printf '%s\n' "$hex" ;;
	esac
}

# Run if executed directly (not sourced).
if ! (return 0 2>/dev/null); then
	uuidv7 "$@"
fi
