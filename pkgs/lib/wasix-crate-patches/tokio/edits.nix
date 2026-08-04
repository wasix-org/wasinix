# tokio: the wasi-networking backend patch, floored across 1.47.0+ (a version the
# floor no longer fits hard-fails). Tokio 1.51's target_env = "p1" gates leave
# WASIX's env = "dl" on the supported fd path, so that line needs only the small
# remaining wasm-family residual instead of the pre-1.51 networking port. Below
# 1.47.0 predates the port and builds stock as a transitive dep (its net path is
# not on wasi); main builds those consumers unpatched.
{...}: {
  edited = [">=1.47.0"];
  stock = ["<1.47.0"];
}
