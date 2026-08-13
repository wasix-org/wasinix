# libdd-common: a wasmer get_current_thread_id inserted before the
# unsupported-platform compile_error, then wasmerAsNative narrows that
# compile_error's allowlist (and the crate's wasm32 gates) to admit wasmer.
# get_current_thread_id arrived partway through the line, and a revision without
# it has no platform gate to admit wasmer to.
{rewriters, ...}: {
  edited = ["*"];
  notMinted = "git-sourced via ddtrace (DataDog/libdatadog), not crates.io";
  forVersion = {...}: {
    patchPhase = ''
      if [ -f src/threading.rs ]; then
        patch -p1 < ${./thread-id.patch}
      fi
      ${rewriters.wasmerAsNative}
    '';
  };
}
