# libdd-common: a wasmer get_current_thread_id inserted before the
# unsupported-platform compile_error, then wasmerAsNative narrows that
# compile_error's allowlist (and the crate's wasm32 gates) to admit wasmer.
{rewriters, ...}: {
  edited = ["*"];
  notMinted = "git-sourced via ddtrace (DataDog/libdatadog), not crates.io";
  forVersion = {...}: {
    patches = [./thread-id.patch];
    patchPhase = "${rewriters.wasmerAsNative}";
  };
}
