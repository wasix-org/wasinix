# orjson for wasix. maturin/pyo3-ffi wheel with a yyjson cc shim. Needs the maturin-on-wasix
# wiring (see pydantic-core.nix): cross sysconfig, -fwasm-exceptions for the shim (ehpic PIC),
# and pyo3-ffi/extension-module so the cdylib doesn't link libpython.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  env = {
    CFLAGS = "-fwasm-exceptions";
  };
  maturinBuildFlags = ["--features" "pyo3-ffi/extension-module"];
  # test_memory.py imports psutil, which raises on wasix during collection and
  # aborts the whole run
  disabledTestPaths = ["test/test_memory.py"];
  # nixpkgs' cross-arch-compat.patch is stale for 3.11.9's build.rs (fails to
  # apply). build.rs gates x86_64/aarch64 SIMD (inline_int/str, avx512) on
  # #[cfg(target_arch=...)], evaluated for the x86_64 BUILD host, so it wrongly
  # enables them for the wasm target. wasm needs none: drop the patch and
  # compile those blocks out.
  patches = _: [];
  postPatch = ''
    substituteInPlace build.rs \
      --replace-fail '#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]' '#[cfg(any())]' \
      --replace-fail '#[cfg(all(target_arch = "x86_64", not(target_os = "macos")))]' '#[cfg(any())]'
  '';
}
pyprev.orjson
