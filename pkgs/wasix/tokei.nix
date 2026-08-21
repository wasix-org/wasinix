# tokei: code statistics in Rust.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasix.broken = ''
    it pulls the `home` crate (via its core git2 dependency), which has no wasi
    `home_dir_inner` — fixing it needs a vendored-dependency wasi port. See memory
    note wasix-rust-unix-cfg-gap.'';
}
