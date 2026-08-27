# zbar for wasix, pyzbar's ctypes backend. pyzbar dlopens libzbar.so at import, but
# libtool won't make wasm dylibs (ld_shlibs=no), so it is linked by hand.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  profileSets,
}:
exposeWasixPackage (
  extendPackage (package.override {
    # zbarcam needs V4L2 (/dev/video) and the GTK/Qt viewers need an X display;
    # wasmer has neither.
    enableVideo = false;
    withXorg = false;
    imagemagickBig = packages.sameProfile.imagemagick;
    libintl = null;
  }) {
    passthru.wasix.supportedProfiles = profileSets.pic;
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
    # test_decode includes <argp.h>, a glibc extension wasix-libc lacks, so it
    # fails to compile and takes the whole suite build with it. Remove its
    # check_PROGRAMS entry and per-target variables (automake errors on orphaned
    # test_test_decode_* variables); the remaining mentions name a target
    # nothing builds and are inert. zbar ships no Makefile.in and autoreconfs at
    # build, so editing the .am is enough.
    postPatch = ''
      substituteInPlace test/Makefile.am.inc \
        --replace-fail 'check_PROGRAMS += test/test_decode' ""
      # automake emits one test_test_decode_* variable per SOURCES/OBJECTS/
      # LDADD/DEPENDENCIES/LINK; the exact set isn't fixed, so a prefix match
      # (substituteInPlace has no regex) is what actually clears all of them.
      sed -i '/^test_test_decode_/d' test/Makefile.am.inc
      if grep -q '^test_test_decode_' test/Makefile.am.inc; then
        echo "zbar: test_test_decode_* variables still in Makefile.am.inc"; exit 1
      fi
    '';
    # automake parses the include inside `if HAVE_MAGICK` even with imagemagick
    # off, so `make check` tries to link zbarimg without a sysroot ("cannot open
    # crt1.o"); build only the named test programs.
    wasixCheckPrebuild = ''
      make -j"''${NIX_BUILD_CORES:-1}" ''${zbarTests}
    '';
    # Only test_convert runs: test_proc needs the video/window input thread
    # (features off, spawn fails); test_cpp and test_cpp_img die unwinding
    # through zbar::throw_exception even in the EH profiles (WASIX-TODO.md).
    # test_decode/test_video/test_dbus/test_jpeg are not built at all.
    zbarTests = "test/test_convert";
    # Run the programs directly; `make check` would relink zbarimg in the
    # run-only derivation, which has no compiler.
    checkPhase = ''
      runHook preCheck
      for t in ''${zbarTests}; do
        echo "running $t"
        ./"$t"
      done
      runHook postCheck
    '';
    # without zbarimg there are no man pages; the output must still exist.
    postInstall = ''
      install -Dm755 zbar/.libs/libzbar.so "$lib/lib/libzbar.so"
      mkdir -p "$man/share/man" "$doc/share/doc"
    '';
  }
)
