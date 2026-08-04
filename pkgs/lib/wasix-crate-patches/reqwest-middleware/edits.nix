# reqwest-middleware mirrors reqwest's bare target_arch = "wasm32" gate, which
# wrongly catches wasix and drops the Send futures plus the version/timeout
# builders; browserWasm narrows it, identically across the whole 0.5 line.
{rewriters, ...}: {
  edited = [">=0.5.0"];
  forVersion = {...}: {
    patchPhase = "${rewriters.browserWasm}";
  };
}
