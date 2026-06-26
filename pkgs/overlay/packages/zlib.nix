{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  overrideAttrs = _old: {
    buildPhase = ''
      runHook preBuild
      make -j''${NIX_BUILD_CORES:-1} libz.a
      runHook postBuild
    '';
  };
}
prev.zlib
