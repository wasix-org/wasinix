# getrandom: the 0.3.x wasi backend is gated on target_env = "p1", which our
# wasm32-wasmer-wasi-dl target (env "dl") misses; the patch widens that gate,
# floored across 0.3.3+ (the patch not fitting a future layout hard-fails). The
# 0.2.x line is a different backend without that gate and builds stock (main
# builds every 0.2.x consumer unpatched).
{...}: {
  edited = [">=0.3.3"];
  stock = ["<0.3.0"];
}
