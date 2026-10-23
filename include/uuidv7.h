/*
 * uuidv7 C ABI: the public interface of the pure Zig UUIDv7 core (RFC 9562).
 *
 * The core performs no I/O. Callers supply the current time, a 64-bit random
 * value and the stored counter state, so identical inputs give identical bytes.
 *
 * Buffers are pointer + byte length. Text is ASCII/UTF-8 and need not be
 * NUL-terminated; outputs are never NUL-terminated. A NULL pointer is accepted
 * only where a length of 0 is passed (or where noted). All functions are pure,
 * reentrant and thread-safe; nothing is allocated and no pointer is retained.
 */
#ifndef UUIDV7_H
#define UUIDV7_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Return codes. */
#define UUIDV7_OK              0
#define UUIDV7_ERR_NULL       -1  /* required pointer was NULL */
#define UUIDV7_ERR_BUFFER     -2  /* output capacity too small */
#define UUIDV7_ERR_INVALID    -3  /* malformed input text */
#define UUIDV7_ERR_RANGE      -4  /* number outside the accepted range */

/* Bytes needed for outputs. */
#define UUIDV7_BYTES           16
#define UUIDV7_HYPHENATED_LEN  36
#define UUIDV7_COMPACT_LEN     32
#define UUIDV7_DECIMAL_MAX     21  /* longest extract result: 281474976710656048575 */
#define UUIDV7_STATE_TEXT_MAX  41  /* "<int64>:<uint64>" */

/* Kinds of counter transition (for statistics). */
#define UUIDV7_KIND_NEW        1  /* newer tick: counter reseeded from random */
#define UUIDV7_KIND_SAME_NS    2  /* same tick: counter incremented */
#define UUIDV7_KIND_ROLLBACK   3  /* clock stepped back: time frozen, counter incremented */
#define UUIDV7_KIND_TS_AHEAD   4  /* counter overflow: borrowed the next nanosecond */

typedef struct uuidv7_state {
	int64_t nanotime;  /* effective epoch nanoseconds of the last value */
	uint64_t counter;  /* 54-bit monotonic counter */
} uuidv7_state;

/* Library version, as a static string of *len bytes (not NUL-terminated). */
const char *uuidv7_version(size_t *len);

/*
 * Advance the monotonic counter state. `stored` may be NULL (no prior state).
 * `random` seeds the counter on a new tick or after overflow; *used_random tells
 * whether it was consumed. Static (explicit) timestamps never borrow time.
 */
int uuidv7_advance(const uuidv7_state *stored, int64_t current_ns, int is_static,
	uint64_t random, uuidv7_state *out, uint8_t *kind, uint8_t *used_random);

/* RFC 9562 bytes for nanotime in [0, INT64_MAX] and a 54-bit counter. out_len >= 16. */
int uuidv7_encode(int64_t nanotime, uint64_t counter, uint8_t *out, size_t out_len);

/* Lowercase hex of 16 bytes; 36 chars with hyphens, else 32. */
int uuidv7_format(const uint8_t *bytes, size_t bytes_len, int hyphens,
	char *out, size_t out_cap, size_t *out_len);

/*
 * Decimal epoch time encoded in a UUIDv7 (hyphens anywhere, any case).
 * unit_ns = 0: 48-bit milliseconds; 1: nanoseconds (may exceed 2^64).
 */
int uuidv7_extract(const char *text, size_t text_len, int unit_ns,
	char *out, size_t out_cap, size_t *out_len);

/* Decimal epoch nanoseconds in [0, INT64_MAX]: UUIDV7_ERR_INVALID if not an
 * integer, UUIDV7_ERR_RANGE if an integer outside that range. */
int uuidv7_parse_timestamp(const char *text, size_t text_len, int64_t *out);

/* Milliseconds to nanoseconds; UUIDV7_ERR_RANGE if negative or overflowing. */
int uuidv7_ms_to_ns(int64_t ms, int64_t *out);

/* Windows FILETIME (100 ns ticks since 1601) to Unix epoch nanoseconds. */
int64_t uuidv7_filetime_to_unix_ns(uint64_t filetime);

/* Counter-state file text "<nanotime>:<counter>". */
int uuidv7_state_encode(const uuidv7_state *state, char *out, size_t out_cap, size_t *out_len);

/* Strict inverse of uuidv7_state_encode: UUIDV7_ERR_INVALID for any other text. */
int uuidv7_state_decode(const char *text, size_t text_len, uuidv7_state *out);

/*
 * Daemon client retry policy. A reachable daemon owns the live stream, so a
 * client whose request gets an empty or ERR reply retries the daemon with
 * bounded, growing backoff and never generates locally. The caller performs the
 * socket I/O, the sleeping and the jitter draw.
 */
#define UUIDV7_RETRY_REQUEST_MAX        33  /* "-R<uint32>W<uint64>" */
#define UUIDV7_RETRY_SLEEP               0  /* sleep *sleep_us, then send *next */
#define UUIDV7_RETRY_GIVE_UP_ATTEMPTS    1  /* the attempt cap is reached */
#define UUIDV7_RETRY_GIVE_UP_TIMEOUT     2  /* the next sleep would exceed the wait budget */

typedef struct uuidv7_retry {
	uint32_t attempt;    /* attempt about to be sent, from 1 */
	uint64_t waited_us;  /* backoff already waited */
	uint64_t delay_us;   /* next backoff delay */
} uuidv7_retry;

/* First attempt: attempt 1, nothing waited, 50 us initial delay. */
void uuidv7_retry_init(uuidv7_retry *r);

/* Request line for this attempt, without the newline: "" or "-" (hyphens) on
 * the first attempt, then "R<attempt>W<waited_us>" appended on retries. */
int uuidv7_retry_request(const uuidv7_retry *r, int hyphens, char *out, size_t out_cap, size_t *out_len);

/* 1 when the daemon served the request (a non-empty reply not starting with
 * "ERR"), else 0. */
int uuidv7_reply_served(const char *reply, size_t reply_len);

/* After a refused attempt: *action is one of UUIDV7_RETRY_*. On SLEEP, *sleep_us
 * and *next are set; the delay then grows by floor(delay * (1.5 + jitter / 10)).
 * jitter must be in [0, 1), else UUIDV7_ERR_RANGE. */
int uuidv7_retry_after_refusal(const uuidv7_retry *r, uint32_t max_attempts, uint64_t timeout_us,
	double jitter, uuidv7_retry *next, uint8_t *action, uint64_t *sleep_us);

/* Attempt cap from the texts of UUIDV7_DAEMON_NO_RETRY ("1" or "true", any
 * case: one try) and UUIDV7_DAEMON_RETRIES (decimal >= 1, saturating); else 20.
 * Pass an unset variable as NULL, 0. */
int uuidv7_retry_attempts(const char *no_retry, size_t no_retry_len,
	const char *retries, size_t retries_len, uint32_t *out);

/* Wait budget from the text of UUIDV7_DAEMON_RETRY_TIMEOUT_US (decimal,
 * saturating); else 2000. */
int uuidv7_retry_timeout_us(const char *text, size_t text_len, uint64_t *out);

/*
 * Refused system socket. When the installed system service's socket file exists
 * but connections are refused (the service crashed and left it), the service
 * manager restarts the service. Clients count consecutive refusals in the
 * per-user state directory: the first UUIDV7_SERVICE_RESTARTS fail with a
 * try-again message, later ones are an error. The caller reads and writes the
 * count file.
 */
#define UUIDV7_SERVICE_RESTARTS   3
#define UUIDV7_SERVICE_TRY_AGAIN  0  /* "no service on this request, restarting; please try again" */
#define UUIDV7_SERVICE_GIVE_UP    1  /* the service is not running: an error */

/* From the stored count text (plain decimal; anything else, including empty,
 * counts as no prior refusals): the count to store next and the action, one of
 * UUIDV7_SERVICE_*. Saturates at UINT32_MAX. */
int uuidv7_service_refusal(const char *prior, size_t prior_len, uint32_t *count, uint8_t *action);

#ifdef __cplusplus
}
#endif

#endif /* UUIDV7_H */
