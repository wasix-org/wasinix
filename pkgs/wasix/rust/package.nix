# Thin WebC packaging for the WASIX-hosted stage-2 toolchain built in
# pkgs/toolchain/rust/toolchain.nix.
{
  final,
  helpers,
  toolchain,
  ...
}: let
  base = toolchain.wasixHostedRustToolchain;
  runtime =
    final.runCommand "${base.name}-runtime" {
      inherit (base) pname version meta passthru;
      nativeBuildInputs = [toolchain.binaryen];
    } ''
      cp -a ${base} "$out"
      chmod -R u+w "$out"
      cp -a ${toolchain.wasixRustToolchain}/lib/rustlib/${targetTriple}/lib/. \
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
    n = i: final.lib.toIntBase10 (builtins.elemAt c i);
  in
    assert final.lib.assertMsg (c != null) "rust: version ${v} is not YYYY-MM-DD.REV+rust-MAJOR.MINOR";
    assert final.lib.assertMsg (n 3 < 100) "rust: fork revision ${toString (n 3)} overflows its base-100 version slot"; "${toString (n 0)}.${toString (n 1)}.${toString (n 2 * 100 + n 3)}";
in
  helpers.extendPackage runtime {
    passthru.wasix = {
      shipped = true;
      supportedProfiles = ["eh"];
      preferredProfile = "eh";
      updateNotes = [
        {message = "drop wasix-host-tools.patch once the WASIX Rust target is marked capable of hosting tools upstream";}
        {message = "recheck the stage-2 output layout on every wasix-org/rust bump";}
      ];
    };
    passthru.wasmer = {
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
      dependencies = [final.lld];
      fs."/rust" = runtime;
    };
  }
