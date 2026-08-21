# nixpkgs' pillow links codec/X11 libraries (lcms2, libavif -> glib -> rust,
# libimagequant (rust), libraqm, libxcb) that don't cross-build to wasix. Drop
# them, leaving a minimal codec set (freetype + jpeg/tiff/webp/openjpeg/zlib);
# pillow's setup.py auto-disables features whose libs are absent.
{
  exposeExtendedPackage,
  packages,
  pkgs,
  lib,
  dropInputsByName,
  linkInputs,
}: let
in
  exposeExtendedPackage (
    linkInputs (dropInputsByName ["lcms2" "libavif" "libimagequant" "libraqm" "libxcb"])
    // {
      # the fuzzer tests shell out to `find` at collection; the guest has no
      # coreutils, so collection errors and pytest aborts the entire run
      disabledTestPaths = ["Tests/oss-fuzz/test_fuzzers.py"];
      passthru = old:
        old
        // {
          wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.numpy packages.sameProfile.defusedxml];
          # No suite: the codec paths trip the shared-library GOT/export
          # defect at a different symbol each run, killing the session
          # (WASIX-TODO.md).
          wasinix = (old.wasinix or {}) // {checks.captured.install = false;};
        };
      # lib.const replaces upstream's preConfigure (drops its AVIF/IMAGEQUANT/libxcb roots),
      # keeping only the openjpeg (JPEG2K) root.
      preConfigure = lib.const ''
        substituteInPlace setup.py \
          --replace-fail 'JPEG2K_ROOT = None' 'JPEG2K_ROOT = "${pkgs.openjpeg.out}/lib", "${lib.getDev pkgs.openjpeg}/include"'
      '';
    }
  )
