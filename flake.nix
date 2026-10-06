{
  description = "uuidv7 — RFC 9562 UUIDv7 in LuaJIT: true-nanosecond, strictly monotonic, with a single-threaded UDS daemon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # LuaJIT is the only runtime dependency (ffi + bit are built in).
        runtimeTools = [ pkgs.luajit ];
        # Tools the test suites shell out to (jq validates the JSONL log).
        testTools = with pkgs; [ bashInteractive coreutils gnugrep jq ];
        # Zig 0.16 builds the pure core, its C ABI library and the uuidv7z C CLI.
        zig = pkgs.zig_0_16;

        uuidv7 = pkgs.stdenv.mkDerivation {
          pname = "uuidv7";
          version = "0.2.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = runtimeTools;
          dontBuild = true;
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/lib $out/share/uuidv7/tests
            cp bin/uuidv7 $out/bin/uuidv7
            cp lib/*.lua $out/lib/
            cp tests/uuidv7_test $out/share/uuidv7/tests/uuidv7_test
            chmod +x $out/bin/uuidv7
            patchShebangs $out/bin/uuidv7
            # The CLI, client, and daemon all require modules from $out/lib.
            wrapProgram $out/bin/uuidv7 --set LUA_PATH "$out/lib/?.lua;;"
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "RFC 9562 UUIDv7 generator + UDS daemon (LuaJIT)";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "uuidv7";
          };
        };
        # Portable products: static musl on Linux, the native target on macOS.
        zigTarget = {
          x86_64-linux = "x86_64-linux-musl";
          aarch64-linux = "aarch64-linux-musl";
        }.${system} or "native";

        # uuidv7z: Zig core + C ABI library + C CLI, built by build.zig.
        uuidv7z = pkgs.stdenv.mkDerivation {
          pname = "uuidv7z";
          version = "0.2.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [ ./build.zig ./build.zig.zon ./src ./include ./c ];
          };
          nativeBuildInputs = [ zig ];
          dontConfigure = true;
          dontInstall = true;
          buildPhase = ''
            runHook preBuild
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global" ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
            zig build -Doptimize=ReleaseFast -Dtarget=${zigTarget} --prefix "$out"
            runHook postBuild
          '';
          meta = with pkgs.lib; {
            description = "RFC 9562 UUIDv7: pure Zig core, C ABI library and C CLI";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "uuidv7z";
          };
        };
      in {
        packages.default = uuidv7;
        packages.uuidv7 = uuidv7;
        packages.uuidv7z = uuidv7z;

        # Mechatron Prime CI builds this on every push (x86_64-linux); it runs ./test,
        # the full suite INCLUDING the daemon black-box test, so cross-platform breakage
        # (sockaddr_un, O_NONBLOCK, accept() flag inheritance, etc.) is caught here.
        checks.uuidv7-test = pkgs.runCommand "uuidv7-test"
          { nativeBuildInputs = runtimeTools ++ testTools ++ [ zig pkgs.file ]; } ''
            cp -r ${./.} work
            chmod -R u+w work
            cd work
            patchShebangs bin tests test build
            export HOME="$TMPDIR"
            export PATH="$PWD/bin:$PATH"
            export LUA_PATH="$PWD/lib/?.lua;;"
            export UUIDV7_TEST_FILE="$PWD/tests/uuidv7_test"
            export UUIDV7_SILENCE_INSECURE_RANDOM=1
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global" ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
            bash ./test   # the single complete entry point (every suite)
            luajit bench/uuidv7_bench 50000   # validates the bench runs + its correctness check on Linux
            touch $out
          '';

        devShells.default = pkgs.mkShell {
          packages = runtimeTools ++ testTools ++ [ zig pkgs.file ];
        };
      });
}
