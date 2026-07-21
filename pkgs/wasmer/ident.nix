# Published webc identity (owner/name/semver) of a wasix package. Shared by
# make-wasmer-package (this package and its [dependencies] entries) and the
# wasmer layer (multi-version keying), so a reference always matches how the
# package itself publishes.
{lib}: rec {
  # Coerce a version to semver MAJOR.MINOR.PATCH (wasmer rejects anything
  # else, including leading zeros): "9.0" -> "9.0.0", "5.3p9" -> "5.3.9".
  #
  # A fourth numeric component has nowhere to go: dropping it collides
  # (pandoc 3.7.0.2 and 3.7.0.3 both -> 3.7.0) and every fold that avoids
  # the collision has to cover the package's whole version history to stay
  # monotone, which only the package knows. So refuse, and make it declare a
  # rule in passthru.wasmer.version.
  toSemver = pname: v: let
    digits = builtins.filter (s: builtins.isString s && s != "") (builtins.split "[^0-9]+" v);
    canonical = map (d: toString (lib.toIntBase10 d)) digits;
  in
    if builtins.length canonical > 3
    then
      throw ''
        ${pname}: upstream version "${v}" has ${toString (builtins.length canonical)} numeric components; semver takes 3.
        Truncating would collide with sibling releases, so declare a rule:
          passthru.wasmer.version = v: ...;   # upstream version -> MAJOR.MINOR.PATCH
        It must be monotone over every version this package has published.
      ''
    else lib.concatStringsSep "." (lib.take 3 (canonical ++ ["0" "0" "0"]));

  # Publication release numbers (rels.json at the repo root): keyed by attr
  # path then upstream version, so an upstream bump resets to 1 by key miss.
  # Bump to republish a changed build of the same version; registry versions
  # are immutable.
  rels = builtins.fromJSON (builtins.readFile ../../rels.json);

  # Published webc identity (owner/name/semver) of a wasix package. Used for
  # this package and its dependencies, so a [dependencies] reference always
  # matches how the dependency itself publishes.
  webcIdent = p: let
    pw = p.passthru.wasmer or {};
    name = pw.name or p.meta.mainProgram or p.pname or p.name;
    # the wasinix namespace does not exist on wasmer.io yet; publish under
    # kilyanni until it does
    owner = pw.owner or "kilyanni";
    upstreamVersion = p.version or "0.0.0";
    baseVersion =
      if !(pw ? version)
      then toSemver name upstreamVersion
      else if builtins.isFunction pw.version
      then pw.version upstreamVersion
      else throw "${name}: passthru.wasmer.version must be a function of the upstream version, not a literal; a literal freezes the published version across bumps";
    rel = (rels."wasmerPackages.${name}" or {}).${baseVersion} or 1;
    # no version encoding for rels works on the registry yet (WASIX-TODO.md:
    # build metadata is normalized away, prereleases hide from latest); the
    # rel goes into [package.metadata] as plumbing, but `wasmer package
    # build` strips metadata from the webc too, so a bump does not yet change
    # the published artifact at all
    version = baseVersion;
  in {
    inherit owner name version baseVersion rel;
    fullName = "${owner}/${name}";
  };
}
