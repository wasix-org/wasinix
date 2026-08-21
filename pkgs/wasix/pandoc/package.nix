# pandoc as a wasm32-wasi command (wasmerPackages.pandoc): wasm-opt the pandoc-cli
# from the haskell set and ship it. GHC emits wasm32-wasi and ignores the profile
# EH/PIC flags, so it's one build at the preferred profile, not a per-profile set.
{
  exposePackage,
  extendPackage,
  packages,
  pkgs,
}:
exposePackage (
  let
    inherit (packages.sameProfile) lib;
    pandoc-cli = packages.sameProfile.haskellPackages.pandoc-cli;

    # PVP A.B.C.D has one component too many for semver. Fold D into the patch
    # base-100 (D stays a small packaging revision), uniformly, so 3-component
    # releases keep sorting above 4-component ones with the same A.B.C:
    # 3.7.0.2 -> 3.7.2, 3.7.0.3 -> 3.7.3, 3.7.1 -> 3.7.100, 3.6.4 -> 3.6.400.
    pvpToSemver = v: let
      c = lib.splitString "." v;
      n = i:
        if builtins.length c > i
        then lib.toInt (builtins.elemAt c i)
        else 0;
    in
      assert lib.assertMsg (n 3 < 100) "pandoc ${v}: PVP component 4 >= 100 overflows the base-100 patch fold"; "${toString (n 0)}.${toString (n 1)}.${toString (n 2 * 100 + n 3)}";
  in
    # the standard ghc-wasm post-link wasm-opt pass.
    extendPackage (
      packages.sameProfile.buildPackages.runCommand "pandoc" {
        inherit (pandoc-cli) version; # so the webc is pandoc-<ver>
        nativeBuildInputs = [pkgs.binaryen];
      } ''
        wasm-opt --experimental-new-eh --low-memory-unused --converge --gufa \
          --flatten --rereloop -Oz ${pandoc-cli}/bin/pandoc.wasm -o pandoc.opt.wasm
        install -Dm755 pandoc.opt.wasm "$out/bin/pandoc.wasm"
      ''
    ) {
      passthru.wasinix.shipped = true;
      passthru.wasmer.version = pvpToSemver;
    }
)
