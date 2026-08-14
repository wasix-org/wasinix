# nixpkgs' pillow links codec/X11 libraries (lcms2, libavif -> glib -> rust,
# libimagequant (rust), libraqm, libxcb) that don't cross-build to wasix. Drop
# them, leaving a minimal codec set (freetype + jpeg/tiff/webp/openjpeg/zlib);
# pillow's setup.py auto-disables features whose libs are absent.
{
  pyfinal,
  pyprev,
  final,
  lib,
  helpers,
  ...
}: let
in
  helpers.libTweaks (
    helpers.linkInputs (helpers.dropInputsByName ["lcms2" "libavif" "libimagequant" "libraqm" "libxcb"])
    // {
      # the fuzzer tests shell out to `find` at collection; the guest has no
      # coreutils, so collection errors and pytest aborts the entire run
      disabledTestPaths = ["Tests/oss-fuzz/test_fuzzers.py"];
      passthru = old:
        old
        // {
          wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.numpy pyfinal.defusedxml];
          # No suite: the codec paths trip the shared-library GOT/export
          # defect at a different symbol each run, killing the session
          # (WASIX-TODO.md).
          wasix = (old.wasix or {}) // {installCheck = false;};
        };
      # lib.const replaces upstream's preConfigure (drops its AVIF/IMAGEQUANT/libxcb roots),
      # keeping only the openjpeg (JPEG2K) root.
      preConfigure = lib.const ''
        substituteInPlace setup.py \
          --replace-fail 'JPEG2K_ROOT = None' 'JPEG2K_ROOT = "${final.openjpeg.out}/lib", "${lib.getDev final.openjpeg}/include"'
      '';
    }
  )
  pyprev.pillow
