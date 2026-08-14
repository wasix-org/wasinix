{
  stdenv,
  nix,
  pkg-config,
}: let
  nixDevHash = builtins.substring 11 32 (toString nix.dev);
in
  stdenv.mkDerivation {
    pname = "check-reference-scanner";
    version = "0";

    src = ./check-reference-scanner.cc;
    dontUnpack = true;

    nativeBuildInputs = [pkg-config];
    buildInputs = [nix.dev];

    buildPhase = ''
      runHook preBuild
      $CXX -std=c++20 -Wall -Wextra -Werror $(pkg-config --cflags nix-store) "$src" \
        -o check-reference-scanner $(pkg-config --libs nix-store)
      runHook postBuild
    '';

    doCheck = true;
    checkPhase = ''
      runHook preCheck
      mkdir fixture
      printf '%s\n' '${nix.dev}' '11110011111111111100000001111111' > fixture/paths
      ./check-reference-scanner fixture references
      _expected=$(printf '%s\t%s' '${nixDevHash}' '${nix.dev}')
      grep -Fqx "$_expected" references
      grep -Fqx '11110011111111111100000001111111' references
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 check-reference-scanner "$out/bin/check-reference-scanner"
      runHook postInstall
    '';
  }
