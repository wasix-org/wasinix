# Build one wasix profile as a full nixpkgs cross set (like pkgsStatic):
# re-import nixpkgs with the wasix crossSystem, inject the wasixcc stdenv via
# config.replaceCrossStdenv, and layer the wasix overlay of per-package tweaks
# on top. Every package then builds with wasixcc and linked dependencies
# resolve within the profile.
{
  system,
  nixpkgs,
  mkWasixStdenv,
  productsOverlay,
  wasixOverlay,
}:
# extraOverlays is the spot-override seam (see spot.nix): empty in every normal
# eval, so the overlay list and every drv path are unchanged.
extraOverlays: profileSpec:
import nixpkgs {
  inherit system;
  crossSystem =
    {
      # Shared wasm triple; the profile is carried as custom platform fields
      # (wasmExceptions/wasmPic), which survive elaboration and are read by
      # set/stdenv.nix.
      config = "wasm32-unknown-wasi";
      useLLVM = true;
      isWasix = true;
    }
    // profileSpec;
  config.allowUnsupportedSystem = true;
  config.replaceCrossStdenv = mkWasixStdenv;
  # Shared recipes come first. wasixOverlay layers target/product adaptations
  # over them and remains the only writer of WASIX support meta.
  overlays = [productsOverlay wasixOverlay] ++ extraOverlays;
}
