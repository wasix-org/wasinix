# giflib's hand-written Makefile builds a shared object (libgif.so) via its
# default `all` target. wasix links everything statically and the off profile
# has no PIC sysroot, so the -shared link fails ("PIC without wasm exceptions").
# Build and install the static library only.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace Makefile \
      --replace-fail 'all: shared-lib static-lib $(UTILS)' 'all: static-lib $(UTILS)' \
      --replace-fail 'install-lib: install-static-lib install-shared-lib' 'install-lib: install-static-lib'
  '';
}
prev.giflib
