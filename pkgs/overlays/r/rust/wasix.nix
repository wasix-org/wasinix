# Thin WebC packaging for the WASIX-hosted stage-2 toolchain built in
# pkgs/toolchain/rust/toolchain.nix.
{
  exposeWasixPackage,
  extendPackage,
  packages,
  pkgs,
}:
exposeWasixPackage (
  let
    base = packages.native."wasix-rust".override {hostedOnWasix = true;};
    runtime =
      packages.sameProfile.runCommand "${base.name}-runtime" {
        inherit (base) pname version meta passthru;
        nativeBuildInputs = [pkgs.binaryen];
      } ''
        cp -a ${base} "$out"
        chmod -R u+w "$out"
        cp -a ${packages.native."wasix-rust"}/lib/rustlib/${targetTriple}/lib/. \
          "$out/lib/rustlib/${targetTriple}/lib/"
        for tool in rustc cargo; do
          wasm-opt "$out/bin/$tool.wasm" -O3 \
            --enable-bulk-memory --enable-threads --enable-reference-types \
            --no-validation --emit-exnref --strip-debug \
            -o "$out/bin/$tool.wasm.opt"
          mv "$out/bin/$tool.wasm.opt" "$out/bin/$tool.wasm"
        done
      '';
    targetTriple = "wasm32-wasmer-wasi";
    forkVersionToSemver = v: let
      c = builtins.match "([0-9]{4})-([0-9]{2})-([0-9]{2})\\.([0-9]+)\\+rust-[0-9]+\\.[0-9]+" v;
      n = i: packages.sameProfile.lib.toIntBase10 (builtins.elemAt c i);
    in
      assert packages.sameProfile.lib.assertMsg (c != null) "rust: version ${v} is not YYYY-MM-DD.REV+rust-MAJOR.MINOR";
      assert packages.sameProfile.lib.assertMsg (n 3 < 100) "rust: fork revision ${toString (n 3)} overflows its base-100 version slot"; "${toString (n 0)}.${toString (n 1)}.${toString (n 2 * 100 + n 3)}";
  in
    extendPackage runtime {
      passthru = {
        wasix = {
          supportedProfiles = ["eh"];
          preferredProfile = "eh";
        };
        wasinix = {
          shipped = true;
          update.notes = [
            {message = "drop wasix-host-tools.patch once the WASIX Rust target is marked capable of hosting tools upstream";}
            {message = "recheck the stage-2 output layout on every wasix-org/rust bump";}
          ];
        };
        wasmer = {
          name = "rust";
          entrypoint = "rustc";
          # The dated fork release is the package version. Fold day and revision
          # into semver's patch component: 2026-07-07.3 -> 2026.7.703.
          version = forkVersionToSemver;
          commands = [
            {
              name = "rustc";
              module = "rustc";
              wasm = "rustc.wasm";
              output = "rustc.wasm";
              mainArgs = ["--sysroot=/rust"];
            }
            {
              name = "cargo";
              module = "cargo";
              wasm = "cargo.wasm";
              output = "cargo.wasm";
              env = {
                RUSTC = "/bin/rustc";
                PATH = "/bin";
                CARGO_HOME = "/tmp/cargo-home";
                CARGO_INCREMENTAL = "0";
                CARGO_BUILD_TARGET = targetTriple;
                CARGO_TARGET_WASM32_WASMER_WASI_LINKER = "/bin/wasm-ld";
              };
            }
          ];
          dependencies = [packages.sameProfile.lld];
          fs."/rust" = runtime;
        };
      };
    }
)
