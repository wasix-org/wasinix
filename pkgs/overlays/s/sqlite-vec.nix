# Preserve the native package metadata because Python packages inherit it
# before the declared-broken cross dependency is filtered from test inputs.
{
  exposeWasixPackage,
  packages,
}:
exposeWasixPackage (
  let
    native = packages.sameProfile.buildPackages.sqlite-vec;
  in
    packages.sameProfile.buildPackages.runCommand "sqlite-vec-unsupported" {
      inherit (native) pname version src;
      passthru.wasix.broken = "needs hostPlatform.extensions.sharedLibrary; wasm32-wasi has no dynamic loader (hasSharedLibraries=false).";
    } ''
      echo "sqlite-vec is not supported on wasix: no shared-library extension" >&2
      exit 1
    ''
)
