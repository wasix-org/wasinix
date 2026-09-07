{
  lib,
  abiCheck,
  cxxRuntimeCheck,
}: {
  packageAbi = {
    entry,
    packages,
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
      label = "${entry.variant.profile}-${entry.name}-${entry.instance.version}";
      # A static main asks for the same setting to link its own C++ objects; only
      # a PIC main hands the runtime on to side modules.
      carriesCxxRuntime =
        traits.pic
        && (entry.package.drvAttrs.WASIXCC_INCLUDE_CPP_SYMBOLS or null) == "yes";
    in {
      tests =
        {
          abi = abiCheck {
            name = label;
            paths = [entry.package];
            inherit (traits) eh pic;
            dylink = traits.pic;
          };
        }
        // lib.optionalAttrs carriesCxxRuntime {
          cxx-runtime = cxxRuntimeCheck {
            name = label;
            inherit (entry) package;
            inherit (packages.sameProfile) stdenv;
          };
        };
    });
}
