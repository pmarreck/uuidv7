{
  description = "uuidv7 — RFC 9562 UUIDv7 in LuaJIT: true-nanosecond, strictly monotonic, with a single-threaded UDS daemon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    {
      # services.uuidv7.enable = true runs the machine-wide service (Linux, systemd).
      nixosModules.default = import ./nix/module.nix { inherit self; };
    } // flake-utils.lib.eachDefaultSystem (system:
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
            # systemd units for the machine-wide service (used by nixosModules.default).
            mkdir -p $out/lib/systemd/system
            cp contrib/systemd/uuidv7.socket contrib/systemd/uuidv7.service $out/lib/systemd/system/
            substituteInPlace $out/lib/systemd/system/uuidv7.service \
              --replace-fail /usr/local/bin/uuidv7 $out/bin/uuidv7
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
      in pkgs.lib.recursiveUpdate {
        packages.default = uuidv7;
        packages.uuidv7 = uuidv7;
        packages.uuidv7z = uuidv7z;

        # Mechatron Prime CI builds this on every push (x86_64-linux); it runs ./test,
        # the full suite INCLUDING the daemon black-box test, so cross-platform breakage
        # (sockaddr_un, O_NONBLOCK, accept() flag inheritance, etc.) is caught here.
        checks.uuidv7-test = pkgs.runCommand "uuidv7-test"
          { nativeBuildInputs = runtimeTools ++ testTools ++ [ zig pkgs.file ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.systemd ]; } ''
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
          # systemd-socket-activate drives the socket-activation suite on Linux.
          packages = runtimeTools ++ testTools ++ [ zig pkgs.file ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.systemd ];
        };
      } (pkgs.lib.optionalAttrs (system == "x86_64-linux") {
        # The Windows toolchain for real-host test runs (./test-windows): a static
        # LuaJIT executable needing no lua51.dll. The check inspects the binary
        # itself rather than trusting the build flags.
        packages.luajit-windows-x86_64 =
          let
            static = pkgs.pkgsCross.mingwW64.luajit.overrideAttrs (old: {
              makeFlags = old.makeFlags ++ [ "BUILDMODE=static" ];
            });
          in pkgs.runCommand "luajit-windows-x86_64" { } ''
            mkdir -p $out/bin
            cp -L ${static}/bin/luajit $out/bin/luajit.exe
          '';
        checks.luajit-windows-x86_64 = pkgs.runCommand "luajit-windows-x86_64-check"
          { nativeBuildInputs = [ pkgs.file pkgs.binutils ]; } ''
            exe=${self.packages.${system}.luajit-windows-x86_64}/bin/luajit.exe
            desc=$(file -b "$exe")
            echo "$desc"
            case "$desc" in "PE32+ executable"*console*x86-64*) ;; *) echo "not a PE32+ x86-64 console executable"; exit 1 ;; esac
            dlls=$(objdump -p "$exe" | sed -n 's/^[[:space:]]*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')
            echo "imports: $dlls"
            [ "$dlls" = "kernel32.dll msvcrt.dll " ] || { echo "unexpected DLL imports"; exit 1; }
            touch $out
          '';
        # A NixOS VM with services.uuidv7 enabled (needs KVM on the builder).
        checks.service-vm = import ./nix/service_vm_test.nix { inherit self pkgs; };
      }));
}
