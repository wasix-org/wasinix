# The loadable-extension build needs hostPlatform.extensions.sharedLibrary;
# wasm32-wasi has hasSharedLibraries=false (no dynamic loader), so the
# attribute is absent and nixpkgs' own package.nix throws before a
# derivation exists. Stand in a stub derivation carrying
# passthru.wasix.broken, so anything that pulls sqlite-vec as a checkInput
# sees a declared-broken package instead of an eval-time throw.
{final, ...}:
final.buildPackages.runCommand "sqlite-vec-unsupported" {
  passthru.wasix.broken = "needs hostPlatform.extensions.sharedLibrary; wasm32-wasi has no dynamic loader (hasSharedLibraries=false).";
} ''
  echo "sqlite-vec is not supported on wasix: no shared-library extension" >&2
  exit 1
''
