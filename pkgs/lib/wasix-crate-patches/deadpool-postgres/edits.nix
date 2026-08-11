# The wasm32 branch is the browser backend; WASI needs the native pool path.
{rewriters, ...}: {
  edited = [">=0.14.1"];
  forVersion = _: {
    patchPhase = "${rewriters.browserWasm}";
  };
}
