# The wasm32 branch is the browser backend; WASI needs the native socket path.
{rewriters, ...}: {
  edited = [">=0.7.18"];
  forVersion = _: {
    patchPhase = "${rewriters.browserWasm}";
  };
}
