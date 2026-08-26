{
  exposeWasixPackage,
  lib,
  package,
}:
exposeWasixPackage (
  package.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        wasinix.shipped = true;
        # 0-unstable-YYYY-MM-DD: the date is the whole version, so put it in the
        # patch. 0.0.x leaves room for a real 0.1.0 to sort above the snapshots.
        # Prefer 0.0.0-unstable.YYYY.M.D once wasmer resolves prerelease-only
        # packages (WASIX-TODO.md).
        wasmer.version = v: let
          d = builtins.match ".*-unstable-([0-9]{4})-([0-9]{2})-([0-9]{2})" v;
        in
          assert lib.assertMsg (d != null) "crabsay: version ${v} is not <ver>-unstable-YYYY-MM-DD"; "0.0.${lib.concatStrings d}";
      };
  })
)
