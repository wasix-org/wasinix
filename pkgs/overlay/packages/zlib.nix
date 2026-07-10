{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  buildPhase = _: ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-1} libz.a
    runHook postBuild

    exit 1
  '';
}
prev.zlib
