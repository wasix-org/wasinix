{ lib, stdenvNoCC, fetchurl, gnutar, autoPatchelfHook, stdenv, zlib }:
let
  version = "v2026-02-09.1+rust-1.90";
in
stdenvNoCC.mkDerivation {
  pname = "wasix-rust-toolchain";
  inherit version;

  # Update instructions:
  # 1) Pick a new wasix-org/rust release tag.
  # 2) Update `version`, `url`, and `hash` below.
  # 3) Validate with: nix build .#cargo-wasix
  src = fetchurl {
    url = "https://github.com/wasix-org/rust/releases/download/${version}/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-a2L8EQCITSoX29vk7KwmfUuNNs45NZ/N3S16sMbyp7Y=";
  };

  dontUnpack = true;
  nativeBuildInputs = [ gnutar ] ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib zlib ];

  installPhase = ''
    runHook preInstall

    tmp="$PWD/unpack"
    mkdir -p "$tmp" "$out"
    tar -xzf "$src" -C "$tmp"

    if [ -d "$tmp/bin" ]; then
      cp -R "$tmp"/. "$out"/
    else
      root="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
      cp -R "$root"/. "$out"/
    fi

    chmod -R u+w "$out"
    if [ -d "$out/bin" ]; then
      find "$out/bin" -maxdepth 1 -type f -exec chmod +x '{}' \;
    fi
    if [ -d "$out/lib/rustlib/x86_64-unknown-linux-gnu/bin" ]; then
      find "$out/lib/rustlib/x86_64-unknown-linux-gnu/bin" -maxdepth 1 -type f -exec chmod +x '{}' \;
    fi

    runHook postInstall
  '';
}
