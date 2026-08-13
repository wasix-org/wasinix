# protoc can't cross-build in protobuf's PIC/EH profiles: its plugin runner needs
# fork, which WASIX only supports through asyncify in the off profile. WITH_PROTOC
# points at nixpkgs' native one via $build_protobuf, a build-time shell variable.
#
# Every major the python protobuf attrs pull in needs the same bypass: python
# protobuf N.M.P is paired with the C++ release M.P by an assertion in nixpkgs,
# so protobuf4/5/6 reach past the default attr.
let
  versions = ["25" "29" "33"];
in {
  names = ["protobuf"] ++ map (v: "protobuf_${v}") versions;
  packages = {
    prev,
    helpers,
    ...
  }: let
    inherit (prev) lib;
    tweak = helpers.libTweaks {
      preConfigure = ''
        cmakeFlagsArray+=("-DWITH_PROTOC=$build_protobuf/bin/protoc")
      '';
    };
  in
    {protobuf = tweak prev.protobuf;}
    // lib.genAttrs (map (v: "protobuf_${v}") versions) (n: tweak prev.${n});
}
