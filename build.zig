const std = @import("std");

// Products, installed under the chosen --prefix:
//   lib/libuuidv7.a                    static C ABI library (linked into the CLI)
//   lib/libuuidv7.{so,dylib}, bin/uuidv7.dll   shared C ABI library (LuaJIT FFI oracle tests)
//   include/uuidv7.h                   the C ABI header
//   bin/uuidv7z[.exe]                  C CLI that calls the core only through the C ABI
pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;
	const is_windows = target.result.os.tag == .windows;
	const is_wasm = target.result.cpu.arch.isWasm();

	const ffi_module = b.createModule(.{
		.root_source_file = b.path("src/ffi.zig"),
		.target = target,
		.optimize = optimize,
	});

	// wasm32-freestanding: the pure core alone, as a feasibility check.
	if (is_wasm) {
		const wasm = b.addExecutable(.{ .name = "uuidv7", .root_module = ffi_module });
		wasm.entry = .disabled;
		wasm.rdynamic = true;
		b.installArtifact(wasm);
		return;
	}

	const static_lib = b.addLibrary(.{ .name = "uuidv7", .linkage = .static, .root_module = ffi_module });
	b.installArtifact(static_lib);
	const shared_lib = b.addLibrary(.{
		.name = "uuidv7",
		.linkage = .dynamic,
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/ffi.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	b.installArtifact(shared_lib);
	b.installFile("include/uuidv7.h", "include/uuidv7.h");

	const cli_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
	cli_module.addIncludePath(b.path("include"));
	const c_flags: []const []const u8 = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic" };
	cli_module.addCSourceFile(.{
		.file = b.path("c/uuidv7z.c"),
		// Debug builds announce themselves on stderr (muted by MUTE_DEBUG_STATUS).
		.flags = if (optimize == .Debug) c_flags ++ &[_][]const u8{"-DUUIDV7Z_DEBUG_BUILD=1"} else c_flags,
	});
	cli_module.linkLibrary(static_lib);
	if (is_windows) cli_module.linkSystemLibrary("bcrypt", .{});
	const cli = b.addExecutable(.{ .name = "uuidv7z", .root_module = cli_module });
	b.installArtifact(cli);

	const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
		.root_source_file = b.path("src/uuidv7_test.zig"),
		.target = target,
		.optimize = optimize,
	}) });
	const test_step = b.step("test", "Run the Zig core unit tests");
	test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
