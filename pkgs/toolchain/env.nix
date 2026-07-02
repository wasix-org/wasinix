# The WASIXCC_* environment variables as data, shared by every consumer that
# drives wasixcc: wasixcc.nix, rust/cargo-wasix.nix, set/stdenv.nix, dev-env.nix.
# Render with `exportsOf` (shell exports) or `makeWrapperFlagsOf` (--set flags).
{lib}: rec {
  # Toolchain locations. Install dirs, NOT bin/: wasixcc appends bin/<tool>
  # itself (src/args.rs get_tool_path).
  locationEnv = {
    wasixLlvm,
    binaryen,
    wasixSysroot,
  }: {
    WASIXCC_LLVM_LOCATION = "${wasixLlvm}";
    WASIXCC_BINARYEN_LOCATION = "${binaryen}";
    WASIXCC_SYSROOT_PREFIX = "${wasixSysroot}";
  };

  # Per-profile ABI settings; wasmExceptions is passed through verbatim, and
  # wasixcc selects the sysroot variant from EH/PIC.
  profileEnv = {
    wasmExceptions ? null,
    pic ? false,
  }:
    lib.optionalAttrs (wasmExceptions != null) {WASIXCC_WASM_EXCEPTIONS = wasmExceptions;}
    // {
      WASIXCC_PIC =
        if pic
        then "yes"
        else "no";
    };

  # Autoconf conftest workarounds, for driving arbitrary build systems.
  autoconfEnv = {WASIXCC_AUTOCONF_WORKAROUNDS = "yes";};

  # Route a build's toolchain through wasixcc. wasm-opt stays off here; the
  # stdenv runs it per-package instead.
  ccEnv = {
    CC = "wasixcc";
    CXX = "wasix++";
    LD = "wasixld";
    AR = "wasixar";
    NM = "wasixnm";
    RANLIB = "wasixranlib";
    WASIXCC_RUN_WASM_OPT = "no";
  };

  # Renderers. Attr order is alphabetical; the vars are independent, so fine.
  exportsOf = env:
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env);
  makeWrapperFlagsOf = env:
    lib.concatStringsSep " "
    (lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") env);
}
