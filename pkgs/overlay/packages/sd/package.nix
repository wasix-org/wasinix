# sd — a sed/find-replace alternative in Rust. Just prev.sd: the rustPlatform seam
# (cargo-wasix) builds it, installs the .wasm, and sets the eh profile + meta — the same
# way C packages auto-pick the wasixcc stdenv. Per-package tweaks, if ever needed, use
# libTweaks/overrideAttrs exactly like a C package.
{prev, ...}: prev.sd
