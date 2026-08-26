{exposePackages}: let
  versions = ["25" "29" "33"];
in
  exposePackages (["protobuf"] ++ map (version: "protobuf_${version}") versions)
