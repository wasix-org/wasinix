# tokio: the wasi-networking backend patch, floored across 1.47.0+ (a version the
# floor no longer fits hard-fails). Below 1.47.0 predates it and builds stock as
# a transitive dep (its net path is not on wasi); main builds those consumers
# unpatched.
{...}: {
  edited = [">=1.47.0"];
  stock = ["<1.47.0"];
}
