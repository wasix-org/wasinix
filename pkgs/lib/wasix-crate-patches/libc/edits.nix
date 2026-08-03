# libc: 0.2.177.patch adds the src/wasi/wasix.rs module (applies across 0.2.177
# up to 0.2.188). Below 0.2.177 predates that module and builds stock; extend the
# upper bound after verifying the patch on a newer release (a covered version it
# no longer fits hard-fails).
{...}: {
  edited = [">=0.2.177, <0.2.189"];
  stock = ["<0.2.177"];
}
