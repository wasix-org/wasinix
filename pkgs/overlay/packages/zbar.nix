# zbar for wasix, pyzbar's ctypes backend. Library-only (no video/X/dbus, and
# no imagemagick, which only zbarimg needs). pyzbar dlopens libzbar.so at
# import, so this is the overlay's one shared library: libtool won't make wasm
# dylibs (ld_shlibs=no), so the dylib is linked by hand from the static
# archive; every object is already PIC in the pic profiles.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  configureFlags = [
    "--without-imagemagick"
    # no NLS: keeps gettext (broken at ehpic) out of the closure.
    "--disable-nls"
  ];
  # libtool won't make wasm dylibs, so link the static archive into one by
  # hand. --whole-archive pulls every member (nothing references them yet);
  # --export-all publishes zbar_* to the wasm export table, where ctypes
  # resolves them (the objects carry no dylib export metadata of their own).
  postBuild = ''
    $CC -shared -Wl,--whole-archive zbar/.libs/libzbar.a -Wl,--no-whole-archive \
      -Wl,--export-all -o zbar/.libs/libzbar.so
  '';
  # without zbarimg there are no man pages; the output must still exist.
  postInstall = ''
    install -Dm755 zbar/.libs/libzbar.so "$lib/lib/libzbar.so"
    mkdir -p "$man/share/man" "$doc/share/doc"
  '';
  passthru.wasix.supportedProfiles = helpers.profiles.pic;
}
(prev.zbar.override {
  enableVideo = false;
  withXorg = false;
  imagemagickBig = null;
  libintl = null;
})
