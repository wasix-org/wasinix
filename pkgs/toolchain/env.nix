# The WASIXCC_* environment as data, shared by every consumer that drives wasixcc.
# Render with `exportsOf` (shell exports) or `makeWrapperFlagsOf` (--set flags).
{lib}: rec {
  # Install dirs, NOT bin/: wasixcc appends bin/<tool> itself (src/args.rs).
  locationEnv = {
    wasixLlvm,
    binaryen,
    wasixSysroot,
  }: {
    WASIXCC_LLVM_LOCATION = "${wasixLlvm}";
    WASIXCC_BINARYEN_LOCATION = "${binaryen}";
    WASIXCC_SYSROOT_PREFIX = "${wasixSysroot}";
  };

  # WASIXCC_PIC is a default, not a pin: a stray -fPIC enables PIC and silently
  # switches the sysroot variant. COMPILER_POST_FLAGS countermands it, since
  # wasixcc appends it after every argument and resolves last-wins.
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
      WASIXCC_COMPILER_POST_FLAGS =
        if pic
        then "-fPIC"
        else "-fno-PIC";
    };

  autoconfEnv = {WASIXCC_AUTOCONF_WORKAROUNDS = "yes";};

  # wasm-opt stays off here; the stdenv runs it per-package instead.
  ccEnv = {
    CC = "wasixcc";
    CXX = "wasix++";
    LD = "wasixld";
    AR = "wasixar";
    NM = "wasixnm";
    RANLIB = "wasixranlib";
    WASIXCC_RUN_WASM_OPT = "no";
  };

  exportsOf = env:
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env);
  makeWrapperFlagsOf = env:
    lib.concatStringsSep " "
    (lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") env);
}
