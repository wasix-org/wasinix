# fd: a `find` alternative in Rust.
{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  passthru.wasix.supportedProfiles = ["eh" "ehpic"];
  passthru.wasix.broken = ''
    porting needs per-function wasi arms for code that has no wasi support — jemalloc
    (doesn't cross-build), the `ctrlc` crate (no wasi platform at all), and fd's own
    unix-gated filesystem fns + uid/gid owner filters + is_fifo + the `nix` crate.
    wasix's std::os::unix is the unstable, incomplete `wasi_ext` feature, so a blanket
    cfg(unix)->cfg(unix,wasi) rewrite doesn't work (it leaves 13 errors). See memory
    note wasix-rust-unix-cfg-gap for the full breakdown.'';
}
