{
  stdenv,
  toolchain,
}:
stdenv.mkDerivation {
  pname = "wasix-sh-shim";
  version = "0.1.0";

  src = builtins.path {
    name = "sh-src";
    path = ./.;
  };

  dontConfigure = true;
  hardeningDisable = ["all"];
  doCheck = false;

  buildPhase = ''
    ${toolchain.commonPreConfigure}
    $CC -O2 -o sh.wasm sh.c
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp sh.wasm $out/bin/sh.wasm
    ${toolchain.binaryen}/bin/wasm-opt --asyncify -O2 \
      $out/bin/sh.wasm -o $out/bin/sh.wasm
  '';
}
