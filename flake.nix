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
      in {
        packages.default = uuidv7;
        packages.uuidv7 = uuidv7;

        # Garnix runs this on every push (notably x86_64-linux) — it exercises the
        # full suite INCLUDING the daemon black-box test, so cross-platform breakage
        # (sockaddr_un, O_NONBLOCK, accept() flag inheritance, etc.) is caught here.
        checks.uuidv7-test = pkgs.runCommand "uuidv7-test"
          { nativeBuildInputs = runtimeTools ++ testTools; } ''
            cp -r ${./.} work
            chmod -R u+w work
            cd work
            patchShebangs bin tests
            export HOME="$TMPDIR"
            export PATH="$PWD/bin:$PATH"
            export LUA_PATH="$PWD/lib/?.lua;;"
            export UUIDV7_TEST_FILE="$PWD/tests/uuidv7_test"
            export UUIDV7_SILENCE_INSECURE_RANDOM=1
            luajit tests/uuidv7_json_test
            bash   tests/uuidv7_test
            bash   tests/uuidv7_layout_test
            luajit tests/uuidv7_daemon_test
            bash   tests/uuidv7_extract_test
            luajit tests/uuidv7_fallback_test
            bash   tests/uuidv7_load_test    # concurrency invariants under load
            luajit tests/uuidv7_fuzz_test    # hostile/malformed protocol input
            luajit bench/uuidv7_bench 50000   # validates the bench runs + its correctness check on Linux
            touch $out
          '';

        devShells.default = pkgs.mkShell {
          packages = runtimeTools ++ testTools;
        };
      });
}
