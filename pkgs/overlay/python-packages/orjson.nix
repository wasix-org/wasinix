# orjson for wasix. maturin/pyo3-ffi wheel with a yyjson cc shim. Needs the maturin-on-wasix
# wiring (see pydantic-core.nix): cross sysconfig, -fwasm-exceptions for the shim (ehpic PIC),
# and pyo3-ffi/extension-module so the cdylib doesn't link libpython.
{
  pyprev,
  final,
  helpers,
  ...
}: let
  rust = import ./lib/rust.nix {inherit final;};
in
  helpers.libTweaks {
    env = {
      PYO3_CROSS_LIB_DIR = rust.pyo3CrossLibDir;
      CFLAGS = "-fwasm-exceptions";
    };
    maturinBuildFlags = ["--features" "pyo3-ffi/extension-module"];
  }
  pyprev.orjson
