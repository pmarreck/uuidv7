# Build layout conformance (audit, 2026-10-23)

Target: the fleet cross-platform build convention (platform names `PF` =
`<OS>-<ARCH>` with OS `linux`/`macos`/`mswin` and ARCH `amd64`/`arm64`;
VARIANT `gnu`/`musl` below PF where it applies).

| Item | Today | Convention |
|---|---|---|
| PATH-facing native command | `bin/<os>/<arch>/uuidv7z` (`bin/linux/x86_64/`) | `bin/<PF>/uuidv7z` (`bin/linux-amd64/`) |
| Direct-build product tree | `zig-out/<zig triple>/<profile>/` (`zig-out/x86_64-linux-musl/ReleaseFast/`) | `zig-out/<PF>/[<VARIANT>/]<profile>/` (`zig-out/linux-amd64/musl/ReleaseFast/`) |
| Nix output link | `.nix-out/<zig triple>/ReleaseFast` | `.nix-out/<PF>/[<VARIANT>/]<profile>` |
| Windows OS token | `windows` | `mswin` |
| `.gitignore` | `/bin/linux`, `/bin/macos`, `/bin/windows` | narrow rules for `/bin/<PF>/` |
| `./run` | missing | builds if needed, then runs the selected host CLI |
| `./build --all-plats` | missing (cross builds are ad hoc in `./test-windows`) | builds every declared platform, reports unavailable builders |
| Generic `bin/uuidv7` | portable LuaJIT script | allowed: portable script in generic `bin/` |

Compiler triples (`x86_64-linux-musl`) stay at the `zig build -Dtarget` boundary;
only project-controlled paths change. Callers to update together: `./build`,
`./test` (`--print-prefix` consumer), `./test-windows`, `flake.nix` if it names
paths, README, `.gitignore`. Old `bin/linux/` links stay until checked and moved
to `~/.Trash`, never deleted blindly. Verify per the convention's
verification-and-migration reference before claiming conformance.
