# zlib auto-threads. Custom build: only the static libpotrace, no CLI.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  overrideAttrs = _old: {
    outputs = ["out" "dev"];
    buildPhase = ''
      runHook preBuild
      make -C src -j''${NIX_BUILD_CORES:-1} libpotrace.la
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib" "$dev/include"
      cp src/.libs/libpotrace.a "$out/lib/"
      cp src/potracelib.h "$dev/include/"
      runHook postInstall
    '';
  };
}
prev.potrace
