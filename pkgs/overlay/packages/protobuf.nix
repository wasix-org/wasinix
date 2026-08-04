# protoc can't cross-build in protobuf's PIC/EH profiles: its plugin runner needs
# fork, which WASIX only supports through asyncify in the off profile. WITH_PROTOC
# points at nixpkgs' native one via $build_protobuf, a build-time shell variable.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  preConfigure = ''
    cmakeFlagsArray+=("-DWITH_PROTOC=$build_protobuf/bin/protoc")
  '';
}
prev.protobuf
