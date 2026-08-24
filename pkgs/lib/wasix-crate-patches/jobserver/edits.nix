# jobserver: wasm has in-process token accounting but no cross-process token
# transport, so configuring child inheritance must be a no-op.
_: {
  edited = [">=0.1.34, <0.2.0"];
  stock = ["<0.1.34"];
}
