# freetype/libjpeg/libpng/libtiff/libxml2/libwebp/zlib/curl auto-thread; only the
# *Support flags + the build-platform coreutils + the potrace placeholder are
# overridden. zstd is added explicitly (imagemagick doesn't pull it on its own).
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  profileSets,
}:
exposeWasixPackage (
  let
    lib = packages.sameProfile.lib;
  in
    extendPackage (package.override {
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
      coreutils = packages.sameProfile.buildPackages.coreutils;
      potrace = packages.sameProfile.buildPackages.runCommand "potrace-placeholder" {} ''mkdir -p "$out"'';
    }) {
      # Magick++ throws; the off profile compiles C++ with -fno-exceptions.
      passthru.wasix.supportedProfiles = profileSets.withEh;
      postPatch = ''
        substituteInPlace MagickCore/delegate.c \
          --replace-fail 'child_pid=(pid_t) fork();' 'child_pid=(pid_t) -1; /* WASIX: fork unsupported */'
      '';
      env = {
        CPPFLAGS = "-I${lib.getDev packages.sameProfile.zstd}/include";
        LDFLAGS = "-L${lib.getLib packages.sameProfile.zstd}/lib";
      };
      outputs = _: ["out"];
      buildInputs = bi:
        lib.filter (i: (i.pname or i.name or "") != "potrace")
        ((
            if bi == null
            then []
            else bi
          )
          ++ [packages.sameProfile.zstd]);
      postInstall = _: ''
        mkdir -p "$out/include"
        if ls "$out"/include/ImageMagick-* >/dev/null 2>&1; then
          rm -f "$out/include/ImageMagick"
          ln -s "$(basename "$(echo "$out"/include/ImageMagick-* | awk '{ print $1 }')")" "$out/include/ImageMagick"
        fi
      '';
    }
)
