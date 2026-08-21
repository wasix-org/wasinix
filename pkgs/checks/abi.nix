{
  lib,
  abiCheck,
}: {
  packageAbi = {
    entry,
    profileSets,
    ...
  }:
    lib.optionalAttrs (
      entry.kind
      == "package"
      && entry.scope == "wasix"
      && !(entry.package.meta.broken or false)
    ) (let
      profile = profileSets.table.${entry.variant.profile};
      traits = {
        eh = (profile.wasmExceptions or "no") != "no";
        pic = profile.wasmPic or false;
      };
    in {
      tests.abi = abiCheck {
        name = "${entry.variant.profile}-${entry.name}-${entry.instance.version}";
        paths = [entry.package];
        inherit (traits) eh pic;
        dylink = traits.pic;
      };
    });
}
