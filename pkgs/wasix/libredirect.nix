# LD_PRELOAD interposition needs a dynamic loader; wasm32-wasi has none
# (lib.systems' isStatic = isWasi, unconditional on profile), so nixpkgs'
# own package.nix throws before a derivation exists. Stand in a stub
# derivation carrying passthru.wasix.broken, so anything that pulls
# libredirect as a checkInput sees a declared-broken package instead of an
# eval-time throw.
{
  exposePackage,
  packages,
}:
exposePackage (
  packages.sameProfile.buildPackages.runCommand "libredirect-unsupported" {
    passthru.wasix.broken = "LD_PRELOAD interposition needs a dynamic loader; wasm32-wasi is fully static (hostPlatform.isStatic).";
  } ''
    echo "libredirect is not supported on wasix: no dynamic loader" >&2
    exit 1
  ''
)
