# freetype/libjpeg/libpng/libtiff/libxml2/libwebp/zlib/curl auto-thread; only the
# *Support flags + the build-platform coreutils + the potrace placeholder are
# overridden. zstd is added explicitly (imagemagick doesn't pull it on its own).
{
  final,
  prev,
  helpers,
  ...
}: let
  lib = final.lib;
in
  helpers.libTweaks {
    postPatch = ''
      substituteInPlace MagickCore/delegate.c \
        --replace-fail 'child_pid=(pid_t) fork();' 'child_pid=(pid_t) -1; /* WASIX: fork unsupported */'
    '';
    env = {
      CPPFLAGS = "-I${lib.getDev final.zstd}/include";
      LDFLAGS = "-L${lib.getLib final.zstd}/lib";
    };
    overrideAttrs = old: {
      outputs = ["out"];
      buildInputs =
        lib.filter (i: (i.pname or i.name or "") != "potrace")
        ((old.buildInputs or []) ++ [final.zstd]);
      postInstall = ''
        mkdir -p "$out/include"
        if ls "$out"/include/ImageMagick-* >/dev/null 2>&1; then
          rm -f "$out/include/ImageMagick"
          ln -s "$(basename "$(echo "$out"/include/ImageMagick-* | awk '{ print $1 }')")" "$out/include/ImageMagick"
        fi
      '';
    };
  } (prev.imagemagick.override {
    bzip2Support = false;
    zlibSupport = true;
    libX11Support = false;
    libXtSupport = false;
    fontconfigSupport = false;
    freetypeSupport = true;
    ghostscriptSupport = false;
    libjpegSupport = true;
    djvulibreSupport = false;
    lcms2Support = false;
    openexrSupport = false;
    libjxlSupport = false;
    libpngSupport = true;
    liblqr1Support = false;
    libraqmSupport = false;
    librawSupport = false;
    librsvgSupport = false;
    libtiffSupport = true;
    libxml2Support = true;
    openjpegSupport = true;
    libwebpSupport = true;
    libheifSupport = false;
    fftwSupport = false;
    coreutils = final.buildPackages.coreutils;
    potrace = final.buildPackages.runCommand "potrace-placeholder" {} ''mkdir -p "$out"'';
  })
