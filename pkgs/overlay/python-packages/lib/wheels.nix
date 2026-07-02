# Shared wheel-override helpers. onlyOnWasix is a gate; the others return libTweaks fragments
# (filter functions extendDrv applies to the old values). Import as
# `import ./lib/wheels.nix {inherit lib;}`.
{lib}: rec {
  # Apply a wasix override only to the wasm build (packageOverrides also reach the native
  # pythonForBuild, which must stay unpatched). `overridden` is forced only on wasm.
  onlyOnWasix = pkg: overridden:
    if pkg.stdenv.hostPlatform.isWasix or false
    then overridden
    else pkg;

  # Drop inputs matching any of `names` from BOTH buildInputs and propagatedBuildInputs (the
  # cross python mirrors one into the other).
  dropInputsByName = names: let
    f = xs:
      lib.filter (x: !(lib.any (n: lib.hasInfix n (lib.getName x)) names)) (
        if xs == null
        then []
        else xs
      );
  in {
    buildInputs = f;
    propagatedBuildInputs = f;
  };

  # Strip sphinxHook (+ extraNames, e.g. "myst") and its `doc` output — the docs pass isn't
  # needed and its tools don't cross-build.
  dropSphinxDocs = extraNames: {
    nativeBuildInputs = xs:
      lib.filter (x: let n = lib.getName x; in !(lib.any (m: lib.hasInfix m n) (["sphinx"] ++ extraNames))) (
        if xs == null
        then []
        else xs
      );
    outputs = xs:
      lib.filter (o: o != "doc") (
        if xs == null
        then ["out"]
        else xs
      );
  };
}
