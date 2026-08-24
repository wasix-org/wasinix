# opentelemetry-http gates its blocking reqwest HttpClient impl on
# target_arch = "wasm32", so wasix loses the impl opentelemetry-otlp requires;
# browserWasm narrows the gate to the browser target that actually lacks it.
{rewriters, ...}: {
  edited = [">=0.27.0"];
  forVersion = _: {
    patchPhase = "${rewriters.browserWasm}";
  };
}
