{
  final,
  lib,
  phpVersion,
}: let
  getDev = lib.getDev;
  extensionPassthru = attrs: attrs // {inherit phpVersion;};
in {
  imagick =
    final.buildPackages.runCommand "php-extension-imagick-3.8.1" {
      passthru = extensionPassthru {
        extensionName = "imagick";
        configureFlag = "--with-imagick";
        buildInputs = [final.imagemagick];
        # PECL ships these headers; cross install must not regenerate them with target PHP.
        crossPostBuild = ''
          touch ext/imagick/*_arginfo.h
        '';
        env = {
          IM_IMAGEMAGICK_CFLAGS = "-I${getDev final.imagemagick}/include/ImageMagick -DIM_MAGICKWAND_HEADER_STYLE_SEVEN -DMAGICKCORE_QUANTUM_DEPTH=16 -DMAGICKCORE_HDRI_ENABLE=1 -DMAGICKCORE_CHANNEL_MASK_DEPTH=32";
          IM_IMAGEMAGICK_LIBS = "-lMagickWand-7.Q16HDRI -lMagickCore-7.Q16HDRI -ltiff -lz -ldeflate -ljpeg -llzma -lzstd -lpng16 -lwebpmux -lwebpdemux -lwebp -lsharpyuv -lfreetype -lxml2 -lcurl -lssl -lcrypto";
        };
      };
    } ''
      mkdir -p "$out"
      tar --strip-components=1 -xf ${final.fetchurl {
        url = "https://pecl.php.net/get/imagick-3.8.1.tgz";
        hash = "sha256-OjWHwKUkwX0NrZZzoWC5DNd26DaDhHThc7VJ7YZDUu4=";
      }} -C "$out"
      substituteInPlace "$out/config.m4" \
        --replace-fail \
          '# This line checks that ImageMagick is available, and
      # meets our minimum supported version. TODO change to 6.7.0
      IM_FIND_IMAGEMAGICK([6.5.3], [$PHP_IMAGICK])' \
          ""
    '';

  igbinary =
    final.buildPackages.runCommand "php-extension-igbinary-edda7101" {
      passthru = extensionPassthru {
        extensionName = "igbinary";
        configureFlag = "--enable-igbinary";
      };
    } ''
      cp -R --no-preserve=mode,ownership ${final.fetchFromGitHub {
        owner = "igbinary";
        repo = "igbinary";
        rev = "edda7101adf583df047d028a154abf3bf04ced61";
        hash = "sha256-EY3fSQjR0/tuEyNvY7ZYpArtmQNebbMyoa2OhGVkWvE=";
      }} "$out"
    '';
}
