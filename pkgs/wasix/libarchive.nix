# libarchive for wasix (nix-util links it for tarball extraction).
# archive_read_disk_posix.c hard-requires fchdir (#error without HAVE_FCHDIR),
# which wasix-libc lacks (WASIX-TODO.md); configure's link test passes anyway
# because wasm-ld tolerates the undefined symbol. A declaration plus an ENOSYS
# stub keeps the archive_read_disk API linkable; only directory-tree reading
# uses it, and nix only reads archives from memory/fds.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.libarchive {
  # no emulated check: all 5 test binaries (libarchive_test, bsdtar_test,
  # bsdcpio_test, bsdcat_test, bsdunzip_test) trap with "out of bounds
  # memory access" immediately in main, before any real test logic runs
  # (WASIX-TODO.md). The shipped library itself is unaffected.
  doCheck = false;
  wasixCheckPrebuild = ":";
  postPatch = ''
    cat > wasix-fchdir.h <<'EOF'
    #ifndef _WASIX_FCHDIR_H
    #define _WASIX_FCHDIR_H
    int fchdir(int);
    #endif
    EOF
    cat > wasix-fchdir.c <<'EOF'
    #include <errno.h>
    int fchdir(int fd) { (void)fd; errno = ENOSYS; return -1; }
    EOF
  '';
  preConfigure = ''
    $CC -c wasix-fchdir.c -o wasix-fchdir.o
    $AR rcs libwasix-fchdir.a wasix-fchdir.o
    export NIX_LDFLAGS="''${NIX_LDFLAGS-} -L$PWD -lwasix-fchdir"
    # AC_CHECK_FUNCS' `char fchdir();` probe clashes with any real declaration,
    # so the header only goes in for the build proper (below).
    export ac_cv_func_fchdir=yes
  '';
  preBuild = ''
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE-} -include $PWD/wasix-fchdir.h"
  '';
  # The stub has to sit inside libarchive.a itself: a separate archive only
  # satisfies libarchive's own link, leaving the symbol undefined for whoever
  # links the static library later.
  postInstall = ''
    $AR r "''${lib-$out}/lib/libarchive.a" wasix-fchdir.o
  '';
}
