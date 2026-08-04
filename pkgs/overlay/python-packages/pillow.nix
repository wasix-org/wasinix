# Three of nixpkgs' pillow libraries do not cross-build to wasix: libavif (through
# gdk-pixbuf -> glib -> bash, which only builds in the off-EH profile), libimagequant
# (cargo-c: "The target wasi-p1 is not supported yet") and libxcb (its xorgproto meson
# rejects wasix-libc's fd_set). setup.py then turns AVIF/quantize/xcb off.
{
  pyprev,
  final,
  lib,
  helpers,
  ...
}:
helpers.libTweaks (
  helpers.linkInputs (helpers.dropInputsByNameInfix ["libavif" "libimagequant" "libxcb"])
  // {
    # Replaces upstream's preConfigure, keeping only the openjpeg root
    preConfigure = _: ''
      substituteInPlace setup.py \
        --replace-fail 'JPEG2K_ROOT = None' 'JPEG2K_ROOT = "${final.openjpeg.out}/lib", "${lib.getDev final.openjpeg}/include"'
    '';
  }
)
pyprev.pillow
