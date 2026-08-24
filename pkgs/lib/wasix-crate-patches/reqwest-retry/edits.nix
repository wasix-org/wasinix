# reqwest-retry mirrors reqwest's bare target_arch = "wasm32" gate, which wrongly
# catches wasix and drops the Send futures its middleware trait requires;
# browserWasm narrows it, as for reqwest-middleware.
{rewriters, ...}: {
  edited = [">=0.7.0"];
  forVersion = _: {
    patchPhase = "${rewriters.browserWasm}";
  };
}
