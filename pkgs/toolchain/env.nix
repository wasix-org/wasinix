# The WASIXCC_* environment contract, as data — the single source for every
# consumer that drives wasixcc: the wasixcc bin wrappers (wasixcc.nix), the
# cargo-wasix wrapper (rust/cargo-wasix.nix), the stdenv shim (set/stdenv.nix)
# and the devShell/test export fragments (dev-env.nix). Render an env attrset
# with `exportsOf` (shell exports) or `makeWrapperFlagsOf` (--set flags).
{lib}: rec {
  # Locations of the toolchain pieces. Install dirs, NOT bin/ — wasixcc joins
  # bin/<tool> onto user-provided locations itself (src/args.rs get_tool_path).
  locationEnv = {
    wasixLlvm,
    binaryen,
    wasixSysroot,
  }: {
    WASIXCC_LLVM_LOCATION = "${wasixLlvm}";
    WASIXCC_BINARYEN_LOCATION = "${binaryen}";
    WASIXCC_SYSROOT_PREFIX = "${wasixSysroot}";
  };

  # Per-profile ABI knobs (values are what WASIXCC_WASM_EXCEPTIONS expects; the
  # sysroot variant is selected from EH/PIC).
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

  # Autoconf conftest workarounds — for driving arbitrary build systems.
  autoconfEnv = {WASIXCC_AUTOCONF_WORKAROUNDS = "yes";};

  # Route a build's toolchain through wasixcc. wasm-opt stays off for plain
  # `make`-style consumers (the stdenv runs it per-package instead).
  ccEnv = {
    CC = "wasixcc";
    CXX = "wasix++";
    LD = "wasixld";
    AR = "wasixar";
    NM = "wasixnm";
    RANLIB = "wasixranlib";
    WASIXCC_RUN_WASM_OPT = "no";
  };

  # Renderers. Attr order is alphabetical (attrset semantics) — fine, the vars
  # are independent.
  exportsOf = env:
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env);
  makeWrapperFlagsOf = env:
    lib.concatStringsSep " "
    (lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") env);
}
