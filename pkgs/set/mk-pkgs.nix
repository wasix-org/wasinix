# Build one wasix profile as a full nixpkgs cross set (like pkgsStatic):
# re-import nixpkgs with the wasix crossSystem, inject the wasixcc stdenv via
# config.replaceCrossStdenv, and layer the wasix overlay of per-package tweaks
# on top. Every package then builds with wasixcc and linked dependencies
# resolve within the profile.
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
  overlays = [wasixOverlay];
}
