# libpng/libjpeg auto-thread; the *Support flags are build options (kept).
{
  exposeWasixPackage,
  extendPackage,
  package,
}:
exposeWasixPackage (
  extendPackage (package.override {
    threadingSupport = false;
    pngSupport = true;
    jpegSupport = true;
    tiffSupport = false;
    gifSupport = false;
  }) {}
)
