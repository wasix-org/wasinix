# Build one wasix profile as a full nixpkgs cross package set — the same shape as
# nixpkgs' own `pkgsStatic`/`pkgsMusl`: re-import nixpkgs with the wasix
# crossSystem and inject the wasixcc stdenv via `config.replaceCrossStdenv`.
#
# The result is a complete package set where every package builds with wasixcc
# and linked dependencies auto-thread within the profile (no manual `self.X`).
# The wasixOverlay layers our per-package tweaks on top.
{
  system,
  nixpkgs,
  mkWasixStdenv,
  wasixOverlay,
}: profileSpec:
import nixpkgs {
  inherit system;
  crossSystem =
    {
      # Shared wasm triple; the profile rides as custom platform fields
      # (wasmExceptions/wasmPic), which survive elaboration and are read by
      # mk-wasix-stdenv.nix.
      config = "wasm32-unknown-wasi";
      useLLVM = true;
      isWasix = true;
    }
    // profileSpec;
  config.allowUnsupportedSystem = true;
  config.replaceCrossStdenv = mkWasixStdenv;
  overlays = [wasixOverlay];
}
