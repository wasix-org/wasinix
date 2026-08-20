# oniguruma provides regex; jq doesn't fork, so no asyncify. jq bakes
# ${tzdata}/share/zoneinfo for its date built-ins; cross tzdata doesn't build
# for WASIX (localtime.c uses getresuid/tzname/...), and zoneinfo is plain
# data, so use the build-platform tzdata. tz-aware date functions just won't
# find the store path at runtime in the sandbox.
#
# Older releases (webc history, packages/history.json) build here too via the
# loader's src rebase; the version conditionals below carry the drift.
{
  final,
  prev,
  helpers,
  ...
}: let
  lib = prev.lib;
  base = prev.jq.override {tzdata = final.buildPackages.tzdata;};
  # jq < 1.7 bundles oniguruma under modules/ (not vendor/), ships no git so
  # scripts/version must be stubbed to the release version, and predates the
  # test file nixpkgs' current patch targets.
  old = lib.versionOlder base.version "1.7";
in
  helpers.wasmRename {wasmName = "jq";} (
    helpers.extendPackage base ({
        passthru.wasinix.shipped = true;
        # jq's postFixup strips $dev/$man/$doc refs from the binary to break a
        # bin<->dev output cycle; retarget it at jq.wasm, since wasmRename's
        # postInstall renamed $bin/bin/jq before fixup runs.
        postFixup = _: ''
          remove-references-to -t "$dev" -t "$man" -t "$doc" "$bin/bin/jq.wasm"
        '';
      }
      // lib.optionalAttrs old {
        # nixpkgs' patches target 1.8 test files; tests don't run cross anyway.
        patches = _: [];
        preBuild = _: "rm -rf ./vendor/oniguruma ./modules/oniguruma\n";
        preConfigure = _: ''
          echo "#!/bin/sh" > scripts/version
          echo "echo ${base.version}" >> scripts/version
          patchShebangs scripts/version
        '';
      })
  )
