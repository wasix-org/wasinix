# pyopenssl for wasix. nixpkgs builds it multi-output for the sphinx docs and
# attaches propagatedBuildInputs to dev, so a dependent propagating pyopenssl gets
# a dev output with no python module and `import OpenSSL` raises ModuleNotFoundError.
#
# Releases below 26 read _lib.GEN_EMAIL, a cffi binding cryptography dropped in
# 49, so a rebased build takes the newest cryptography history entry that still
# declares it. 23.3.0 caps cryptography below 42, under everything the set ships,
# so it takes the oldest entry and skips the runtime dependency check.
{
  exposeExtendedPackage,
  packages,
  package,
  lib,
  dropSphinxDocs,
  replaceInputsByName,
}: let
  version = package.version;
  cryptography =
    if lib.versionOlder version "25"
    then packages.sameProfile.cryptography.versions."43.0.3"
    else if lib.versionOlder version "26"
    then packages.sameProfile.cryptography.versions."46.0.7"
    else null;
in
  exposeExtendedPackage (
    dropSphinxDocs []
    # dev holds no module, so keep out (module) + dist (wheel) only.
    // {
      outputs = _: ["out" "dist"];
      pytestFlags = ["--import-mode=importlib"];
      disabledTests = ["TestDTLS" "test_connect_refused" "test_connect_ex" "test_moving_buffer_behavior"];
    }
    // lib.optionalAttrs (cryptography != null) {
      propagatedBuildInputs = replaceInputsByName {inherit cryptography;};
    }
    // lib.optionalAttrs (lib.versionOlder version "24") {dontCheckRuntimeDeps = true;}
  )
