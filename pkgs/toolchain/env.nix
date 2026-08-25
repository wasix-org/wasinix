# The WASIXCC_* environment as data, shared by every consumer that drives wasixcc.
# Render with `exportsOf` (shell exports) or `makeWrapperFlagsOf` (--set flags).
{lib}: {
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

  # Per-profile ABI settings; wasmExceptions is passed through verbatim, and
  # wasixcc selects the sysroot variant from EH/PIC.
  #
  # WASIXCC_PIC is a default, not a pin: wasixcc documents that a -fPIC flag
  # enables PIC, silently switching to the PIC sysroot (and erroring at off,
  # which has none). Build systems pass -fPIC unconditionally (cmake,
  # hardening), so the profile pins its PIC mode with a countermanding
  # COMPILER_POST_FLAGS entry, which wasixcc appends after all arguments
  # (response files included) and resolves last-wins. COMPILER_POST_FLAGS
  # entries are ':'-separated (wasixcc's own list syntax, not shell words).
  #
  # -mno-wide-arithmetic countermands the same way: wasixcc enables the feature
  # on every compile. The rust side is turned off in the target spec.
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
        (
          if pic
          then "-fPIC"
          else "-fno-PIC"
        )
        + ":-mno-wide-arithmetic";
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
