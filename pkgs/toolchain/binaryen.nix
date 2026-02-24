{ lib, stdenvNoCC, fetchurl, gnutar, autoPatchelfHook, stdenv }:
let
  version = "126";
in
stdenvNoCC.mkDerivation {
  pname = "binaryen";
  inherit version;

  src = fetchurl {
    url = "https://github.com/WebAssembly/binaryen/releases/download/version_${version}/binaryen-version_${version}-x86_64-linux.tar.gz";
    hash = "sha256-5Ifg6sHwKmc5gWxhcnCwM+XT+MqQQ5MB/QKGRgMi/XY=";
  };

  dontUnpack = true;
  nativeBuildInputs = [ gnutar ] ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    tmp="$(mktemp -d)"
    tar -xzf "$src" -C "$tmp"
    cp -a "$tmp"/binaryen-version_${version}/. "$out"/
    chmod -R u+w "$out"
    runHook postInstall
  '';
}
