{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # Function form drops nixpkgs' default preConfigure (CHOST/AR fixups
  # targeting autoconf, which zlib's hand-written configure is not).
  preConfigure = _: "";
  # gzguts.h includes <errno.h> only in the !NO_STRERROR branch, but gzread.c
  # and gzwrite.c use errno unconditionally; include it always.
  postPatch = _: ''
    sed -i '1i #include <errno.h>' gzguts.h
  '';
  buildFlags = ["libz.a"];
  # `check` links the shared example; teststatic execs ./example and
  # ./minigzip directly (empty $(QEMU_RUN) prefix), which the shebang makes
  # runnable.
  checkTarget = "teststatic";
  # teststatic both builds and runs, and TESTS= means nothing to zlib's
  # hand-written Makefile, so link the test programs ahead of time.
  wasixCheckPrebuild = ''make -j"''${NIX_BUILD_CORES:-1}" example minigzip'';
}
prev.zlib
