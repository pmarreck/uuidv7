/*
 * uuidv7z: C CLI over the pure Zig UUIDv7 core, using only the C ABI in
 * uuidv7.h. This file owns all I/O (clock, OS randomness, the locked counter
 * state file, argv/env, stdout/stderr); every decision about bits, parsing and
 * ordering is made by the core. Behavior mirrors the LuaJIT `uuidv7` CLI except
 * for the daemon (LuaJIT-only) and --test.
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
#include <windows.h>
#include <bcrypt.h>
#include <fcntl.h>
#include <io.h>
#include <wchar.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__) || defined(__APPLE__)
#include <sys/random.h>
#endif
#endif

#define PROG "uuidv7z"
#define STATE_FILE "uuidv7z-sequence"

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
	int fd = open(path, O_CREAT | O_RDWR, 0666);
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

static _Noreturn void refuse_range(const char *s) {
	fprintf(stderr, PROG ": timestamp out of range: %s (expected 0 to 9223372036854775807 nanoseconds since the Unix epoch)\n", s);
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
		"\n"
		"Strict ordering across processes comes from an exclusively locked counter file,\n"
		"$TMPDIR/uuidv7z-sequence (Windows: %TMPDIR%, %TEMP% or %TMP%). The daemon\n"
		"(--daemon, --api) exists only in the LuaJIT `uuidv7`.\n"
		"Env: TMPDIR, UUIDV7_NS_EXTRACT_OK, UUIDV7_SILENCE_INSECURE_RANDOM.\n"
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
	if (argc == 1) {
		generate(0, 0, 0);
		return 0;
	}

	/* The last argument, if an integer, is the explicit timestamp. */
	int64_t static_ns = 0;
	int has_static = 0;
	const char *last = argv[argc - 1];
	int rc = uuidv7_parse_timestamp(last, strlen(last), &static_ns);
	if (rc == UUIDV7_ERR_RANGE) refuse_range(last);
	has_static = rc == UUIDV7_OK;

	const char *a = argv[1];
	if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
		show_help();
	} else if (!strcmp(a, "--about") || !strcmp(a, "-a")) {
		size_t vl;
		const char *v = uuidv7_version(&vl);
		printf(PROG " %.*s Generate RFC 9562 UUIDv7 with nanosecond precision (" ARCH "-" OS ")\n", (int)vl, v);
	} else if (!strcmp(a, "--hyphen") || !strcmp(a, "--hyphens") || !strcmp(a, "-")) {
		generate(has_static, static_ns, 1);
	} else {
		int64_t first_ns;
		int frc = uuidv7_parse_timestamp(a, strlen(a), &first_ns);
		if (frc == UUIDV7_ERR_RANGE) refuse_range(a);
		if (frc == UUIDV7_OK) {
			generate(1, first_ns, 0);
		} else {
			fprintf(stderr, PROG ": unknown option '%s'\nTry '" PROG " --help' for usage.\n", a);
			return 1;
		}
	}
	return 0;
}
