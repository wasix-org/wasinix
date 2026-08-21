# zlib auto-threads. Custom build: only the static libpotrace, no CLI.
{exposeExtendedPackage}:
exposeExtendedPackage {
  # no emulated check: the test programs bundle getopt, which collides with
  # wasix-libc's at link.
  doCheck = false;
  outputs = _: ["out" "dev"];
  buildPhase = _: ''
    runHook preBuild
    make -C src -j''${NIX_BUILD_CORES:-1} libpotrace.la
    runHook postBuild
  '';
  installPhase = _: ''
    runHook preInstall
    mkdir -p "$out/lib" "$dev/include"
    cp src/.libs/libpotrace.a "$out/lib/"
    cp src/potracelib.h "$dev/include/"
    runHook postInstall
  '';
}
