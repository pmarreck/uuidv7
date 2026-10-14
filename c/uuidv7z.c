/*
 * uuidv7z: C CLI over the pure Zig UUIDv7 core, using only the C ABI in
 * uuidv7.h. This file owns all I/O (clock, OS randomness, the locked counter
 * state file, the daemon socket, argv/env, stdout/stderr); every decision about
 * bits, parsing, ordering and daemon retries is made by the core. Behavior
 * mirrors the LuaJIT `uuidv7` CLI, which alone can run the daemon (--daemon,
 * --api) and has --test; uuidv7z is a client of a running daemon.
 */
#if defined(__linux__)
#define _DEFAULT_SOURCE
#elif defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

#include "uuidv7.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <afunix.h>
#include <windows.h>
#include <bcrypt.h>
#include <fcntl.h>
#include <io.h>
#include <wchar.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__) || defined(__APPLE__)
#include <sys/random.h>
#endif
#endif

#define PROG "uuidv7z"
#define STATE_FILE "uuidv7-sequence"

#if defined(__x86_64__) || defined(_M_X64)
#define ARCH "x86_64"
#elif defined(__aarch64__) || defined(_M_ARM64)
#define ARCH "aarch64"
#else
#define ARCH "unknown-arch"
#endif
#if defined(__linux__)
#define OS "linux"
#elif defined(__APPLE__)
#define OS "macos"
#elif defined(_WIN32)
#define OS "windows"
#else
#define OS "unknown-os"
#endif

static _Noreturn void die(const char *msg) {
	fputs(msg, stderr);
	exit(1);
}

/* ---- clock ---- */

/* Current wall-clock time in Unix epoch nanoseconds (100 ns ticks on Windows). */
static int64_t now_ns(void) {
#ifdef _WIN32
	FILETIME ft;
	GetSystemTimePreciseAsFileTime(&ft);
	return uuidv7_filetime_to_unix_ns(((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime);
#else
	struct timespec ts;
	if (clock_gettime(CLOCK_REALTIME, &ts) != 0) die(PROG ": clock_gettime(CLOCK_REALTIME) failed\n");
	return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
#endif
}

/* ---- randomness ---- */

static int os_random(uint8_t *buf, size_t len) {
#ifdef _WIN32
	return BCryptGenRandom(NULL, buf, (ULONG)len, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
#elif defined(__linux__)
	return getrandom(buf, len, 0) == (ssize_t)len;
#elif defined(__APPLE__)
	return getentropy(buf, len) == 0;
#else
	return 0;
#endif
}

/* 64 random bits for the counter seed; a loud, mute-able insecure fallback
 * (splitmix64 of the clock) only if the OS CSPRNG fails, as in the LuaJIT CLI. */
static uint64_t random_u64(void) {
	uint8_t b[8];
	if (os_random(b, sizeof b)) {
		uint64_t v = 0;
		for (size_t i = 0; i < sizeof b; i++) v = (v << 8) | b[i];
		return v;
	}
	if (!getenv("UUIDV7_SILENCE_INSECURE_RANDOM"))
		fputs("\x1b[31m" PROG " WARNING: no secure RNG available (the OS random source failed); "
			"falling back to a clock-seeded generator, which is NOT cryptographically secure. "
			"Set UUIDV7_SILENCE_INSECURE_RANDOM=1 to mute this warning.\x1b[0m\n", stderr);
	uint64_t z = (uint64_t)now_ns() + 0x9E3779B97F4A7C15ULL;
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

/* ---- counter state: one exclusively locked file shared by all processes ---- */

/* Read-modify-write of the stored state under an exclusive lock. Without a
 * usable state file, falls back to this process's own (empty) state. */
static uuidv7_state next_state(int64_t current, int is_static) {
	uuidv7_state stored, out;
	uint8_t kind, used;
	int have = 0;
	char text[UUIDV7_STATE_TEXT_MAX + 16];
	size_t text_len = 0;
	uint64_t seed = random_u64();
#ifdef _WIN32
	static const wchar_t *vars[] = { L"TMPDIR", L"TEMP", L"TMP" };
	wchar_t dir[32768] = L".";
	for (size_t i = 0; i < sizeof vars / sizeof vars[0]; i++) {
		DWORD n = GetEnvironmentVariableW(vars[i], dir, 32768);
		if (n > 0 && n < 32768) break;
		wcscpy(dir, L".");
	}
	size_t dl = wcslen(dir);
	while (dl > 0 && (dir[dl - 1] == L'\\' || dir[dl - 1] == L'/')) dir[--dl] = 0;
	wchar_t path[32768 + 32];
	swprintf(path, sizeof path / sizeof path[0], L"%ls\\%ls", dir, L"" STATE_FILE);
	HANDLE h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
		OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	if (h != INVALID_HANDLE_VALUE) {
		OVERLAPPED ov;
		memset(&ov, 0, sizeof ov);
		if (LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK, 0, MAXDWORD, MAXDWORD, &ov)) {
			DWORD got = 0;
			if (ReadFile(h, text, (DWORD)(sizeof text - 1), &got, NULL)) text_len = got;
			have = uuidv7_state_decode(text, text_len, &stored) == UUIDV7_OK;
			uuidv7_advance(have ? &stored : NULL, current, is_static, seed, &out, &kind, &used);
			if (uuidv7_state_encode(&out, text, sizeof text, &text_len) == UUIDV7_OK) {
				DWORD put = 0;
				SetFilePointer(h, 0, NULL, FILE_BEGIN);
				WriteFile(h, text, (DWORD)text_len, &put, NULL);
				SetEndOfFile(h);
			}
			UnlockFileEx(h, 0, MAXDWORD, MAXDWORD, &ov);
			CloseHandle(h);
			return out;
		}
		CloseHandle(h);
	}
#else
	const char *dir = getenv("TMPDIR");
	if (!dir || !*dir) dir = "/tmp";
	size_t dl = strlen(dir);
	while (dl > 0 && dir[dl - 1] == '/') dl--;
	char *path = malloc(dl + sizeof STATE_FILE + 1);
	if (!path) die(PROG ": out of memory\n");
	memcpy(path, dir, dl);
	path[dl] = '/';
	memcpy(path + dl + 1, STATE_FILE, sizeof STATE_FILE);
	/* O_NOFOLLOW: a symlink planted at the state path is refused, never written through. */
	int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0666);
	free(path);
	if (fd >= 0) {
		if (flock(fd, LOCK_EX) == 0) {
			ssize_t n = pread(fd, text, sizeof text - 1, 0);
			if (n > 0) text_len = (size_t)n;
			have = uuidv7_state_decode(text, text_len, &stored) == UUIDV7_OK;
			uuidv7_advance(have ? &stored : NULL, current, is_static, seed, &out, &kind, &used);
			if (uuidv7_state_encode(&out, text, sizeof text, &text_len) == UUIDV7_OK) {
				if (ftruncate(fd, 0) == 0 && pwrite(fd, text, text_len, 0) != (ssize_t)text_len)
					fputs(PROG ": warning: could not write counter state\n", stderr);
			}
			flock(fd, LOCK_UN);
			close(fd);
			return out;
		}
		close(fd);
	}
#endif
	uuidv7_advance(NULL, current, is_static, seed, &out, &kind, &used);
	return out;
}

/* ---- output ---- */

static void emit_line(const char *s, size_t len) {
	fwrite(s, 1, len, stdout);
	fputc('\n', stdout);
	if (fflush(stdout) != 0 || ferror(stdout)) exit(1);
}

static void generate(int has_static, int64_t static_ns, int hyphens) {
	uuidv7_state st = next_state(has_static ? static_ns : now_ns(), has_static);
	uint8_t bytes[UUIDV7_BYTES];
	char text[UUIDV7_HYPHENATED_LEN];
	size_t len;
	if (uuidv7_encode(st.nanotime, st.counter, bytes, sizeof bytes) != UUIDV7_OK ||
		uuidv7_format(bytes, sizeof bytes, hyphens, text, sizeof text, &len) != UUIDV7_OK)
		die(PROG ": internal error encoding a UUID\n");
	emit_line(text, len);
}

/* ---- daemon client: route live generation to a running `uuidv7 --daemon` ---- */

#ifdef _WIN32
typedef SOCKET sock_t;
#define BAD_SOCK INVALID_SOCKET
#define sock_close closesocket
#define SHUT_WR SD_SEND
#else
typedef int sock_t;
#define BAD_SOCK (-1)
#define sock_close close
#endif
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
#define DAEMON_REPLY_MAX 4096

/* The daemon's socket: $UUIDV7_SOCK, else uuidv7.sock in XDG_RUNTIME_DIR, TMPDIR,
 * (Windows) TEMP or TMP, or /tmp, with trailing '/' removed: the same lookup as
 * the LuaJIT client, so both find the same daemon. Caller frees. */
static char *daemon_socket_path(void) {
	const char *sock = getenv("UUIDV7_SOCK");
	if (sock) {
		char *p = malloc(strlen(sock) + 1);
		if (!p) die(PROG ": out of memory\n");
		return strcpy(p, sock);
	}
	const char *base = getenv("XDG_RUNTIME_DIR");
	if (!base) base = getenv("TMPDIR");
#ifdef _WIN32
	if (!base) base = getenv("TEMP");
	if (!base) base = getenv("TMP");
#endif
	if (!base) base = "/tmp";
	size_t bl = strlen(base);
	while (bl > 0 && base[bl - 1] == '/') bl--;
	static const char name[] = "/uuidv7.sock";
	char *p = malloc(bl + sizeof name);
	if (!p) die(PROG ": out of memory\n");
	memcpy(p, base, bl);
	memcpy(p + bl, name, sizeof name);
	return p;
}

/* One request on a fresh connection: send `line` plus a newline, half-close,
 * then read the whole reply (anything past `cap` bytes is discarded). Returns 0
 * when no daemon accepts the connection, else 1 with the reply in `reply`. */
static int daemon_oneshot(const char *path, const char *line, size_t line_len,
	char *reply, size_t cap, size_t *reply_len) {
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof addr);
	addr.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof addr.sun_path) return 0;
	strcpy(addr.sun_path, path);
	sock_t s = socket(AF_UNIX, SOCK_STREAM, 0);
	if (s == BAD_SOCK) return 0;
#ifdef SO_NOSIGPIPE
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
	if (connect(s, (const struct sockaddr *)&addr, sizeof addr) != 0) {
		sock_close(s);
		return 0;
	}
	char msg[UUIDV7_RETRY_REQUEST_MAX + 1];
	memcpy(msg, line, line_len);
	msg[line_len] = '\n';
	for (size_t sent = 0; sent < line_len + 1;) {
		int n = (int)send(s, msg + sent, (int)(line_len + 1 - sent), MSG_NOSIGNAL);
		if (n <= 0) break;
		sent += (size_t)n;
	}
	shutdown(s, SHUT_WR);
	size_t got = 0;
	char sink[512];
	for (;;) {
		char *dst = got < cap ? reply + got : sink;
		size_t room = got < cap ? cap - got : sizeof sink;
		int n = (int)recv(s, dst, (int)room, 0);
		if (n <= 0) break;
		if (got < cap) got += (size_t)n;
	}
	sock_close(s);
	*reply_len = got;
	return 1;
}

static void sleep_us(uint64_t us) {
	if (us == 0) return;
#ifdef _WIN32
	/* Sleep() has millisecond granularity: wait out short backoffs on the
	 * performance counter, as the LuaJIT client does. */
	if (us >= 2000) { Sleep((DWORD)(us / 1000)); return; }
	LARGE_INTEGER freq, t0, t;
	QueryPerformanceFrequency(&freq);
	QueryPerformanceCounter(&t0);
	int64_t ticks = (int64_t)(freq.QuadPart * (int64_t)us / 1000000);
	do { Sleep(0); QueryPerformanceCounter(&t); } while (t.QuadPart - t0.QuadPart < ticks);
#else
	struct timespec ts = { (time_t)(us / 1000000), (long)(us % 1000000) * 1000 };
	nanosleep(&ts, NULL);
#endif
}

/* Retry jitter in [0, 1): splitmix64 of the clock. Only de-synchronizes
 * competing clients, so it needs no cryptographic quality. */
static double jitter_unit(uint64_t *s) {
	uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return (double)((z ^ (z >> 31)) >> 11) * 0x1p-53;
}

static size_t env_text(const char *name, const char **out) {
	*out = getenv(name);
	return *out ? strlen(*out) : 0;
}

/* Serve a live request from a running daemon. Returns 0 when no daemon is
 * reachable (local generation is then correct); returns 1 after printing the
 * daemon's reply. A daemon that answers but will not serve within the retry
 * budget is an error: generating locally could sort out of order against the
 * daemon's stream, so this exits 1 instead of falling back. */
static int try_daemon(int hyphens) {
	if (getenv("UUIDV7_NO_DAEMON")) return 0;
	char *path = daemon_socket_path();
#ifdef _WIN32
	WSADATA wsa;
	if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { free(path); return 0; }
#endif
	const char *nr, *rt, *to;
	size_t nrl = env_text("UUIDV7_DAEMON_NO_RETRY", &nr);
	size_t rtl = env_text("UUIDV7_DAEMON_RETRIES", &rt);
	size_t tol = env_text("UUIDV7_DAEMON_RETRY_TIMEOUT_US", &to);
	uint32_t max_attempts;
	uint64_t timeout_us, seed = (uint64_t)now_ns();
	if (uuidv7_retry_attempts(nr, nrl, rt, rtl, &max_attempts) != UUIDV7_OK ||
		uuidv7_retry_timeout_us(to, tol, &timeout_us) != UUIDV7_OK)
		die(PROG ": internal error reading the daemon retry settings\n");
	uuidv7_retry r;
	uuidv7_retry_init(&r);
	char line[UUIDV7_RETRY_REQUEST_MAX], reply[DAEMON_REPLY_MAX];
	size_t line_len, reply_len;
	for (;;) {
		if (uuidv7_retry_request(&r, hyphens, line, sizeof line, &line_len) != UUIDV7_OK)
			die(PROG ": internal error building a daemon request\n");
		if (!daemon_oneshot(path, line, line_len, reply, sizeof reply, &reply_len)) { free(path); return 0; }
		if (uuidv7_reply_served(reply, reply_len) == 1) {
			free(path);
			fwrite(reply, 1, reply_len, stdout);
			if (fflush(stdout) != 0 || ferror(stdout)) exit(1);
			return 1;
		}
		uuidv7_retry next;
		uint8_t action;
		uint64_t pause;
		if (uuidv7_retry_after_refusal(&r, max_attempts, timeout_us, jitter_unit(&seed), &next, &action, &pause) != UUIDV7_OK)
			die(PROG ": internal error in the daemon retry policy\n");
		if (action != UUIDV7_RETRY_SLEEP) {
			while (reply_len > 0 && (reply[reply_len - 1] == '\n' || reply[reply_len - 1] == '\r' ||
				reply[reply_len - 1] == ' ' || reply[reply_len - 1] == '\t')) reply_len--;
			fprintf(stderr, PROG ": daemon at %s is reachable but would not serve a UUID ", path);
			if (action == UUIDV7_RETRY_GIVE_UP_TIMEOUT)
				fprintf(stderr, "within the %lluus retry timeout (%lu attempts, waited %lluus)",
					(unsigned long long)timeout_us, (unsigned long)r.attempt, (unsigned long long)r.waited_us);
			else if (r.attempt <= 1)
				fputs("and retries are disabled (UUIDV7_DAEMON_NO_RETRY)", stderr);
			else
				fprintf(stderr, "after %lu attempts (waited %lluus)", (unsigned long)r.attempt, (unsigned long long)r.waited_us);
			if (reply_len > 0) fprintf(stderr, " (last reply: %.*s)", (int)reply_len, reply);
			fputs("; refusing to silently generate locally (that could break monotonicity). "
				"Retry, raise UUIDV7_DAEMON_RETRY_TIMEOUT_US, or stop the daemon with `uuidv7 --api +++`.\n", stderr);
			free(path);
			exit(1);
		}
		sleep_us(pause);
		r = next;
	}
}

static _Noreturn void refuse_range(const char *s) {
	fprintf(stderr, PROG ": timestamp out of range: %s (expected 0 to 9223372036854775807 nanoseconds since the Unix epoch)\n", s);
	exit(1);
}

/* Report a bad argument (fmt has one %s) with the usage hint, then exit 1. */
static _Noreturn void usage_error(const char *fmt, const char *arg) {
	fputs(PROG ": ", stderr);
	fprintf(stderr, fmt, arg);
	fputs("\nTry '" PROG " --help' for usage.\n", stderr);
	exit(1);
}

static int is_daemon_flag(const char *a) {
	return !strcmp(a, "--daemon") || !strcmp(a, "--api") || !strcmp(a, "--raw") || !strcmp(a, "--socket-api");
}

static void show_help(void) {
	fputs(
		"uuidv7z - Generate RFC 9562 compliant UUIDv7 (time-ordered, strictly monotonic)\n"
		"          Zig core + C CLI; the LuaJIT `uuidv7` is its reference implementation.\n"
		"\n"
		"Usage: uuidv7z [options] [nanoseconds-from-epoch]\n"
		"\n"
		"Options:\n"
		"  --hyphen, --hyphens, -      Output with hyphens\n"
		"  -h, --help                  Show this help message\n"
		"  --about, -a                 One line: name, version, platform\n"
		"  --extract-timestamp <uuid>  Recover the epoch timestamp encoded in a UUIDv7\n"
		"  --extract-timestamp-ms <uuid>   ... as unix milliseconds (default)\n"
		"  --extract-timestamp-ns <uuid>   ... as unix nanoseconds (sub-ms precision)\n"
		"                              Accepts hyphenated or compact, any capitalization.\n"
		"                              -ns warns (sub-ms bits are only meaningful for UUIDs\n"
		"                              from this tool); mute with --mute-warning or\n"
		"                              UUIDV7_NS_EXTRACT_OK=1.\n"
		"\n"
		"Arguments:\n"
		"  nanoseconds-from-epoch      Optional explicit timestamp, 0 to 9223372036854775807\n"
		"  Options and the timestamp may appear in any order; if several timestamps are\n"
		"  given, the last one wins. After --, every argument is a timestamp. Any other\n"
		"  argument is an error.\n"
		"\n"
		"Strict ordering across processes comes from an exclusively locked counter file,\n"
		"$TMPDIR/uuidv7-sequence (Windows: %TMPDIR%, %TEMP% or %TMP%), shared with the\n"
		"LuaJIT `uuidv7`. When a `uuidv7 --daemon` is running, live generation is served\n"
		"by it, so both CLIs draw from one counter; explicit timestamps stay local. If a\n"
		"reachable daemon will not serve, uuidv7z retries it and then exits 1 rather than\n"
		"generating locally. Only the LuaJIT `uuidv7` runs the daemon (--daemon, --api).\n"
		"Env: TMPDIR, UUIDV7_SOCK, UUIDV7_NO_DAEMON, UUIDV7_DAEMON_RETRIES,\n"
		"  UUIDV7_DAEMON_RETRY_TIMEOUT_US, UUIDV7_DAEMON_NO_RETRY, UUIDV7_NS_EXTRACT_OK,\n"
		"  UUIDV7_SILENCE_INSECURE_RANDOM.\n"
		"\n"
		"Examples:\n"
		"  uuidv7z                      Generate UUID without hyphens\n"
		"  uuidv7z --hyphen             Generate UUID with hyphens\n"
		"  uuidv7z 1234567890123456789  Generate UUID with a static timestamp\n",
		stdout);
}

static int ns_warning_muted(void) {
	const char *v = getenv("UUIDV7_NS_EXTRACT_OK");
	if (!v) return 0;
	char low[8];
	size_t n = strlen(v);
	if (n >= sizeof low) return 0;
	for (size_t i = 0; i <= n; i++) low[i] = (char)((v[i] >= 'A' && v[i] <= 'Z') ? v[i] + 32 : v[i]);
	return !strcmp(low, "1") || !strcmp(low, "true");
}

static void extract(int argc, char **argv, int unit_ns) {
	const char *uuid = NULL;
	int muted = 0;
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--mute-warning")) muted = 1;
		else if (!uuid) uuid = argv[i];
		else {
			fprintf(stderr, PROG ": unexpected argument '%s' (%s takes one UUID)\n", argv[i], argv[1]);
			exit(1);
		}
	}
	if (!uuid) uuid = "";
	char out[UUIDV7_DECIMAL_MAX];
	size_t len;
	if (uuidv7_extract(uuid, strlen(uuid), unit_ns, out, sizeof out, &len) != UUIDV7_OK) {
		fprintf(stderr, PROG ": expected 32 hex digits (with or without hyphens), got: %s\n", uuid);
		exit(1);
	}
	if (unit_ns && !muted && !ns_warning_muted())
		fputs("\x1b[31m" PROG " WARNING: nanosecond extraction is only meaningful for "
			"UUIDv7s generated by this tool; other RFC 9562 v7 UUIDs have random sub-millisecond "
			"bits, so the ns value below is unreliable for them. The millisecond field is always "
			"valid. Pass --mute-warning or set UUIDV7_NS_EXTRACT_OK=1 to mute this.\x1b[0m\n", stderr);
	emit_line(out, len);
}

int main(int argc, char **argv) {
#ifdef _WIN32
	_setmode(_fileno(stdout), _O_BINARY);  /* "\n" line endings, as on Unix */
#endif
#ifdef UUIDV7Z_DEBUG_BUILD
	if (!getenv("MUTE_DEBUG_STATUS")) fputs("\x1b[33mDEBUG BUILD!\x1b[0m\n", stderr);
#endif
	if (argc > 1 && is_daemon_flag(argv[1])) {
		fprintf(stderr, PROG ": %s is not supported by " PROG " (the daemon is part of the LuaJIT uuidv7)\n", argv[1]);
		return 1;
	}
	if (argc > 1 && (!strcmp(argv[1], "--extract-timestamp") || !strcmp(argv[1], "--extract-timestamp-ms") ||
		!strcmp(argv[1], "--extract-timestamp-ns"))) {
		extract(argc, argv, !strcmp(argv[1], "--extract-timestamp-ns"));
		return 0;
	}
	/* Generation arguments, parsed left to right in any order: hyphen flags, an
	 * explicit timestamp (the last one wins; every one must be in range), and
	 * help/about (the last one wins). Anything else is an error, even alongside
	 * help, so a typo is never silently ignored. After "--", all are timestamps. */
	int hyphens = 0, has_static = 0, operands_only = 0;
	enum { GENERATE, HELP, ABOUT } action = GENERATE;
	int64_t static_ns = 0;
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		int64_t v;
		int rc = uuidv7_parse_timestamp(a, strlen(a), &v);
		if (rc == UUIDV7_ERR_RANGE) refuse_range(a);
		if (rc == UUIDV7_OK) { static_ns = v; has_static = 1; }
		else if (operands_only) usage_error("unexpected argument '%s' (expected a nanosecond timestamp)", a);
		else if (!strcmp(a, "--")) operands_only = 1;
		else if (!strcmp(a, "--hyphen") || !strcmp(a, "--hyphens") || !strcmp(a, "-")) hyphens = 1;
		else if (!strcmp(a, "-h") || !strcmp(a, "--help")) action = HELP;
		else if (!strcmp(a, "--about") || !strcmp(a, "-a")) action = ABOUT;
		else if (a[0] == '-') usage_error("unknown option '%s'", a);
		else usage_error("unexpected argument '%s' (expected a nanosecond timestamp)", a);
	}
	if (action == HELP) {
		show_help();
	} else if (action == ABOUT) {
		size_t vl;
		const char *v = uuidv7_version(&vl);
		printf(PROG " %.*s Generate RFC 9562 UUIDv7 with nanosecond precision (" ARCH "-" OS ")\n", (int)vl, v);
	} else if (has_static || !try_daemon(hyphens)) {
		generate(has_static, static_ns, hyphens);
	}
	return 0;
}
