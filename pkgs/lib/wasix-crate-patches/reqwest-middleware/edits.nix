# reqwest-middleware mirrors reqwest's bare target_arch = "wasm32" gate, which
# wrongly catches wasix and drops the Send futures plus the version/timeout
# builders; browserWasm narrows it, identically across the 0.4 and 0.5 lines.
{rewriters, ...}: {
  edited = ["=0.4.2" ">=0.5.0"];
  forVersion = _: {
    patchPhase = "${rewriters.browserWasm}";
  };
}
