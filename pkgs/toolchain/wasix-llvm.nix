{ lib, stdenvNoCC, fetchurl, gnutar, autoPatchelfHook, stdenv }:
let
  version = "21.1.203";
in
stdenvNoCC.mkDerivation {
  pname = "wasix-llvm";
  inherit version;

  # Update instructions:
  # 1) Pick a new wasix-org/llvm-project release tag.
  # 2) Update `version`, `url`, and `hash` below.
  # 3) Run: nix flake lock
  # 4) Validate with: nix build .#wasixcc
  src = fetchurl {
    url = "https://github.com/wasix-org/llvm-project/releases/download/${version}/LLVM-Linux-x86_64.tar.gz";
    hash = "sha256-PY/diViHY2ua/Y1jcTUiyTlDARp+J0vwDsB18Rggr5Y=";
  };

  dontUnpack = true;
  nativeBuildInputs = [ gnutar ] ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    tar -xzf "$src" -C "$out"
    chmod -R u+w "$out"
    runHook postInstall
  '';
}
