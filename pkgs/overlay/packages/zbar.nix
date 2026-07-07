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
  # Loose objects, not --whole-archive: the cc wrapper reorders linker args,
  # losing the bracketing (the archive contributed nothing, 633-byte dylib).
  # --export-all: the objects aren't built with dylib exports in mind, and
  # ctypes resolves zbar_* through the wasm export table.
  postBuild = ''
    mkdir dylib-objs
    (cd dylib-objs && $AR x ../zbar/.libs/libzbar.a)
    $CC -shared -Wl,--export-all -o zbar/.libs/libzbar.so dylib-objs/*.o
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
