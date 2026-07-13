# rsync for wasix. It fork()s (server/generator/receiver split), so it is
# asyncified at link and gets git's fork shim (fork() is hidden under the EH
# profiles and absent from libc.a). ACL/xattr support is dropped: WASI has no
# ACLs or extended attributes. popt/xxhash/zstd/lz4/openssl/zlib come from the
# overlay (xxhash is the NEON-fixed overlay lib, see packages/xxhash.nix);
# iconv/perl/python stay build-platform tools.
{
  final,
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.shipped = true;
  # fork() needs asyncified binaries; wasixcc only asyncifies in the off profile
  # on its own, so apply the pass here too (see git/findutils).
  env.WASIXCC_WASM_OPT_FLAGS = "--asyncify:-O2";

  # No ACLs or xattrs under WASI; configure would otherwise probe and misdetect.
  configureFlags = [
    "--disable-acl-support"
    "--disable-xattr-support"
  ];

  postPatch = ''
    # git's wasix-compat shim: unistd.h declaring fork() + proc.c implementing it
    # via __wasi_proc_fork. TODO: lift wasix-compat into shared overlay infra.
    mkdir -p wasix-compat
    cp ${../gitMinimal/wasix-compat/unistd.h} wasix-compat/unistd.h
    cp ${../gitMinimal/wasix-compat/proc.c} wasix-compat/proc.c

    # wasix-libc gaps rsync trips over, force-included below:
    #  - <sys/sysmacros.h> makedev/major/minor: no device nodes; stub them
    #    (mknod fails at runtime anyway).
    #  - fchdir / chroot: absent from libc.a; ENOSYS stubs in wasix-stubs.c.
    #    rsync's pop_dir falls back to a saved path; chroot is daemon-only.
    cat > wasix-compat/wasix-devmacros.h <<'EOF'
    #ifndef _WASIX_DEVMACROS_H
    #define _WASIX_DEVMACROS_H
    #ifndef makedev
    #define makedev(maj, min) ((unsigned)0)
    #endif
    #ifndef major
    #define major(dev) ((unsigned)0)
    #endif
    #ifndef minor
    #define minor(dev) ((unsigned)0)
    #endif
    int fchdir(int);
    int chroot(const char *);
    /* WASI has no POSIX file locking; give the F_*LK/F_*LCK values (locks fail
       at runtime with EINVAL) so fcntl() lock calls in util1.c compile. */
    #ifndef F_GETLK
    #define F_GETLK 5
    #define F_SETLK 6
    #define F_SETLKW 7
    #endif
    #ifndef F_RDLCK
    #define F_RDLCK 0
    #define F_WRLCK 1
    #define F_UNLCK 2
    #endif
    #endif
    EOF
    cat > wasix-compat/wasix-stubs.c <<'EOF'
    #include <errno.h>
    int chroot(const char *p) { (void)p; errno = ENOSYS; return -1; }
    int fchdir(int fd) { (void)fd; errno = ENOSYS; return -1; }
    EOF
  '';
  preConfigure = ''
    export ac_cv_func_fork=yes
    export ac_cv_func_vfork=yes
    $CC -c wasix-compat/proc.c -o wasix-compat/proc.o
    $CC -c wasix-compat/wasix-stubs.c -o wasix-compat/wasix-stubs.o
    $AR rcs wasix-compat/libwasix-compat.a wasix-compat/proc.o wasix-compat/wasix-stubs.o
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE-} -I$PWD/wasix-compat -include $PWD/wasix-compat/wasix-devmacros.h"
    export NIX_LDFLAGS="''${NIX_LDFLAGS-} -L$PWD/wasix-compat -lwasix-compat"
  '';

  passthru.wasmer.entrypoint = "rsync";
  postInstall = ''
    if [ -f "$out/bin/rsync" ]; then
      mv "$out/bin/rsync" "$out/bin/rsync.wasm"
    fi
  '';
} (prev.rsync.overrideAttrs (old: {
  buildInputs =
    builtins.filter (d: !builtins.elem (d.pname or d.name or "") ["acl"]) (old.buildInputs or []);
}))
