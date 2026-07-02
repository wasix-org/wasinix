# pillow for wasix. nixpkgs' pillow links codec/X11 libraries (lcms2, libavif → glib → rust,
# libimagequant (rust), libraqm, libxcb) that don't cross-build to wasix. Drop them, leaving
# the minimal codec set build-scripts uses (freetype + jpeg/tiff/webp/openjpeg/zlib); pillow's
# setup.py auto-disables the features whose libs are absent.
{
  pyprev,
  final,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
in
  helpers.libTweaks (
    wheels.dropInputsByName ["lcms2" "libavif" "libimagequant" "libraqm" "libxcb"]
    // {
      # lib.const replaces upstream's preConfigure (drops its AVIF/IMAGEQUANT/libxcb roots),
      # keeping only the openjpeg (JPEG2K) root.
      preConfigure = lib.const ''
        substituteInPlace setup.py \
          --replace-fail 'JPEG2K_ROOT = None' 'JPEG2K_ROOT = "${final.openjpeg.out}/lib", "${lib.getDev final.openjpeg}/include"'
      '';
    }
  )
  pyprev.pillow
