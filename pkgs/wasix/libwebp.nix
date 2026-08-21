# libpng/libjpeg auto-thread; the *Support flags are build options (kept).
{
  exposePackage,
  extendPackage,
  package,
}:
exposePackage (
  extendPackage (package.override {
    threadingSupport = false;
    pngSupport = true;
    jpegSupport = true;
    tiffSupport = false;
    gifSupport = false;
  }) {}
)
