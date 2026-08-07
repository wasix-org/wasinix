# async-std treats every wasm32 target as a browser while simultaneously
# selecting its native executor for WASIX. Narrow the browser gates so WASIX
# consistently uses async-io and async-global-executor.
{rewriters, ...}: {
  edited = [">=1.0.0"];
  forVersion = {...}: {
    patchPhase = "${rewriters.wasmerAsNative}";
  };
}
