# libpng/libjpeg auto-thread; the *Support flags are build options (kept).
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {} (prev.libwebp.override {
  threadingSupport = false;
  pngSupport = true;
  jpegSupport = true;
  tiffSupport = false;
  gifSupport = false;
})
