# reqwest gates its browser-fetch client on bare target_arch = "wasm32", which
# wrongly catches wasix; browserWasm narrows that gate so wasi/wasmer takes the
# native hyper backend. Version-independent, so it covers and mints the 0.11
# and 0.12 lines identically; ring/rustix in its cone build stock on wasix.
{rewriters, ...}: {
  edited = [">=0.11.0"];
  forVersion = _: {
    patchPhase = "${rewriters.browserWasm}";
  };
}
