# The publishable form of a built wheel, akin to a package's .webc: the same
# artifact restated under its publication release (+wasix.N) and, where the
# entry is built for fewer interpreters than the index serves, the
# Requires-Python bound that says so.
#
# Shared because both sides need it: the wheel set exposes it as `.published`,
# and the registry calls it for the closure members that have no worklist entry
# of their own. A rel bump rewrites this cheap derivation, never the wheel.
{
  pkgs,
  lib,
}: let
  rels = builtins.fromJSON (builtins.readFile ../rels.json);

  interpreters = {
    py313 = "3.13";
    py314 = "3.14";
  };

  # A py3-none-any wheel carries no interpreter tag, so without this bound
  # nothing stops a resolver on another interpreter from taking it and then
  # failing on a dep only the built-for one has. `noarch` is the opposite mark
  # (build once, serve everywhere), so it never bounds.
  requiresPythonOf = variants:
    if variants == null || lib.elem "noarch" variants
    then null
    else let
      allowed =
        lib.sort lib.versionOlder
        (map (v: interpreters.${v}) (lib.intersectLists variants (lib.attrNames interpreters)));
      served = lib.sort lib.versionOlder (lib.attrValues interpreters);
      nextMinor = v: let
        parts = lib.splitString "." v;
      in "${lib.head parts}.${toString (lib.toInt (lib.elemAt parts 1) + 1)}";
      contiguous =
        lib.foldl' (acc: v: {
          ok = acc.ok && (acc.want == null || acc.want == v);
          want = nextMinor v;
        }) {
          ok = true;
          want = null;
        }
        allowed;
    in
      if allowed == served
      then null
      else
        lib.throwIf (!contiguous.ok)
        "python-publish: variants ${toString variants} skip an interpreter, which no single Requires-Python bound can express"
        ">=${lib.head allowed},<${nextMinor (lib.last allowed)}";
in {
  # `suffix` marks PR-preview wheels, whose longer local version sorts above the
  # published one when the preview index is used as an extra index.
  publishOf = {
    drv,
    # The wheel set passes this directly: it marks the entry before the passthru
    # carrying it exists, so reading it back off `drv` would silently see none.
    variants ? (drv.passthru.wasix.variants or null),
    suffix ? null,
  }: let
    name = drv.pname or drv.name;
    rel = (rels."pythonRegistry.wheels.${name}" or {}).${drv.version} or 1;
    requiresPython = requiresPythonOf variants;
  in
    pkgs.runCommand "${name}-${drv.version}+wasix.${toString rel}-published" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      python3 ${./python-registry/publish-wheel.py} ${drv.dist} "$out" \
        --rel ${toString rel} \
        ${lib.optionalString (requiresPython != null) "--requires-python '${requiresPython}'"} \
        ${lib.optionalString (suffix != null) "--version-suffix '${suffix}'"}
    '';
}
