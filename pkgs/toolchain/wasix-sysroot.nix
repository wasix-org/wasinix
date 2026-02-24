{ stdenvNoCC, fetchurl, gnutar }:
let
  version = "v2026-02-16.1";
in
stdenvNoCC.mkDerivation {
  pname = "wasix-sysroot";
  inherit version;

  srcSysroot = fetchurl {
    url = "https://github.com/wasix-org/wasix-libc/releases/download/${version}/sysroot.tar.gz";
    hash = "sha256-IUvuFhdPtPOUQU5knEXE+xwgWVmSCz7LiJ4VlzAjf+0=";
  };
  srcSysrootEh = fetchurl {
    url = "https://github.com/wasix-org/wasix-libc/releases/download/${version}/sysroot-eh.tar.gz";
    hash = "sha256-0avggow76g1qp79SWjN6XbbWCK3P1A69kSYT0bWfkFQ=";
  };
  srcSysrootEhpic = fetchurl {
    url = "https://github.com/wasix-org/wasix-libc/releases/download/${version}/sysroot-ehpic.tar.gz";
    hash = "sha256-6exFF8vtpUdK+tN0QFw0oZTNbRUMImZzd92g+8YfPgg=";
  };

  dontUnpack = true;
  nativeBuildInputs = [ gnutar ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"

    unpack_sysroot() {
      local archive="$1"
      local target="$2"
      local tmp
      tmp="$(mktemp -d)"

      tar -xzf "$archive" -C "$tmp"
      local extracted
      extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

      mkdir -p "$out/$target"
      cp -a "$extracted/sysroot/." "$out/$target/"
    }

    unpack_sysroot "$srcSysroot" "sysroot"
    unpack_sysroot "$srcSysrootEh" "sysroot-eh"
    unpack_sysroot "$srcSysrootEhpic" "sysroot-ehpic"
    runHook postInstall
  '';
}
