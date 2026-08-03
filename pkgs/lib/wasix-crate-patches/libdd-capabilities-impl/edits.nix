# libdd-capabilities-impl gates its native (hyper/tokio) stack off for every wasm32 target;
# wasmerAsNative narrows those gates so wasmer takes the native branch. Version-
# independent, git-sourced via ddtrace.
{rewriters, ...}: {
  edited = ["*"];
  notMinted = "git-sourced via ddtrace (DataDog/libdatadog), not crates.io";
  forVersion = {...}: {
    patchPhase = "${rewriters.wasmerAsNative}";
  };
}
