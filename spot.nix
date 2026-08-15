# Spot-override: rebuild one or more attrs against your working tree while
# everything below them stays on a pristine base revision, so the lower layers
# come from the cache instead of being rebuilt. For experiments ("does my wasixcc
# patch fix this package?"), not for shipping: the output mixes objects built by
# two toolchains, so a green spot build is evidence, not proof.
#
#   nix build -f spot.nix spliced --impure --arg targets '["exnrefEh.zlib"]' \
#     --argstr base "$(git rev-parse HEAD)"
#
# Not a flake output: the base revision is an eval-time input, and nothing here
# may ever become a ci job. The splice itself lives in pkgs/spot.nix.
{
  # Pristine side: a rev whose artifacts are already built (a CI-cached commit).
  # Anything uncached there gets built, which defeats the point.
  base,
  # One or more dotted attr paths into nixpkgsByProfile, e.g. ["exnrefEh.zlib"].
  targets,
  # null defers to the splice's own default (pkgs/spot.nix, the single source).
  keep ? null,
  system ? "x86_64-linux",
  root ? toString ./.,
}: let
  flakeAt = ref: builtins.getFlake "git+file://${root}${ref}";
  # Dirty tree (tracked files, uncommitted edits included) vs the base rev. The
  # splice comes from the work tree: the base rev need not know about spot.
  work = (flakeAt "").legacyPackages.${system};
  baseByProfile = (flakeAt "?rev=${base}").legacyPackages.${system}.nixpkgsByProfile;

  spot = work.spotWith ({inherit baseByProfile targets;}
    // (
      if keep == null
      then {}
      else {inherit keep;}
    ));
in
  spot
  // {
    report = spot.report // {inherit base;};
  }
