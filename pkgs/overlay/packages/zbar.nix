# zbar for wasix, pyzbar's ctypes backend. pyzbar dlopens libzbar.so at import, but
# libtool won't make wasm dylibs (ld_shlibs=no), so it is linked by hand.
{
  final,
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # zbarimg is a C program, but MagickWand's static closure reaches C++ archives
  # (libuhdr), so wasm-ld wants operator new and __cxa_guard_* on the C link.
  env.NIX_LDFLAGS = "-lc++ -lc++abi -lunwind";
  configureFlags = [
    # no NLS: keeps gettext (broken at ehpic) out of the closure.
    "--disable-nls"
  ];
  # --export-all publishes zbar_* to the wasm export table, where ctypes resolves them.
  # libzbar's JPEG decoder is otherwise unresolved and dlopen reports a missing
  # export for jpeg_resync_to_restart.
  postBuild = ''
    $CC -shared -Wl,--whole-archive zbar/.libs/libzbar.a -Wl,--no-whole-archive \
      $($PKG_CONFIG --libs libjpeg) \
      -Wl,--export-all -o zbar/.libs/libzbar.so
  '';
  postInstall = ''
    install -Dm755 zbar/.libs/libzbar.so "$lib/lib/libzbar.so"
    mkdir -p "$man/share/man" "$doc/share/doc"
  '';
  passthru.wasix.supportedProfiles = helpers.profiles.pic;
}
(prev.zbar.override {
  # zbarcam needs V4L2 (/dev/video) and the GTK/Qt viewers need an X display;
  # wasmer has neither.
  enableVideo = false;
  withXorg = false;
  imagemagickBig = final.imagemagick;
  libintl = null;
})
