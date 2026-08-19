# tokio: the wasi-networking backend patch, floored across 1.47.0+ (a version the
# floor no longer fits hard-fails). Tokio 1.51's target_env = "p1" gates leave
# WASIX's env = "dl" on the supported fd path, so the 1.51.0 floor keeps the
# wasm-family rewrite, raw-fd impls, opt-in waker, and signal self-pipe gates.
# Below 1.47.0 upstream rejects the net/fs/process/signal
# features on wasm outright, so those versions are unvetted rather than stock,
# even though a sync-only dependent compiles.
# 1.24.x is not served. The overlay registry's fork builds for it carry 1.20.1
# trees under a 1.24 version number, and serving that silently downgrades a
# security forward-port. An honest port splits cleanly -- a 782-line payload
# (src/process/wasi, src/signal/wasi) copied from a patchPhase as mio's backend
# is, plus the tokio_wasi_classic/tokio_wasix cfg split -- but that payload
# targets 1.20's io driver, which 1.24 replaced with crate::runtime::io.
{...}: {
  edited = ["=1.35.1" ">=1.47.0"];
}
