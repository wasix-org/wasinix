# findutils: find + xargs. Both fork (find -exec, xargs spawns), which on WASIX
# works only via asyncify — so each binary gets a standalone binaryen --asyncify
# pass (the wasixcc link-time pass would also add --enable-eh and abort; this pass
# omits it, like git). coreutils is pinned to the build platform (findutils bakes
# its paths into scripts). Shipped as one webc with find + xargs commands
# (entrypoint find). locate/frcode/updatedb are dropped — they need a runtime
# database, which is useless on wasm.
{
  final,
  prev,
  helpers,
  foundation,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace configure \
      --replace-fail 'as_fn_error $? "could not determine how to read list of mounted file systems" "$LINENO" 5' \
                     'printf "%s\n" "configure: WARNING: could not determine how to read list of mounted file systems; continuing without mountlist support" >&2; ac_list_mounted_fs=found'
    substituteInPlace gl/lib/mountlist.c \
      --replace-fail 'struct mount_entry *mount_list;' \
                     'struct mount_entry *mount_list = NULL;'
    substituteInPlace gl/lib/fts.c \
      --replace-fail 'opendirat((! ISSET(FTS_NOCHDIR)' 'rpl_opendirat((! ISSET(FTS_NOCHDIR)'
    substituteInPlace gl/lib/opendirat.c \
      --replace-fail 'opendirat (int dir_fd, char const *dir, int extra_flags, int *pnew_fd)' \
                     'rpl_opendirat (int dir_fd, char const *dir, int extra_flags, int *pnew_fd)'
    substituteInPlace gl/lib/opendirat.h \
      --replace-fail 'DIR *opendirat (int, char const *, int, int *)' \
                     'DIR *rpl_opendirat (int, char const *, int, int *)'
    substituteInPlace gl/lib/getgroups.c \
      --replace-fail 'getgroups (_GL_UNUSED int n, _GL_UNUSED GETGROUPS_T *groups)' \
                     'getgroups (_GL_UNUSED int n, _GL_UNUSED gid_t *groups)'

    # wasix has native chdir (__wasi_chdir) but no working fchdir, so gnulib's
    # save_cwd (open "." then fchdir to restore) fails on exit with ENOTDIR and
    # find returns non-zero on every run. Skip the fd path so save/restore goes
    # through getcwd + chdir, which work. (Proper fix: __wasi_fchdir in the runtime.)
    substituteInPlace gl/lib/save-cwd.c \
      --replace-fail 'cwd->desc = open (".", O_SEARCH | O_CLOEXEC);' \
                     'cwd->desc = -1; /* wasix: no fchdir; use getcwd + chdir */'
    substituteInPlace Makefile.in \
      --replace-fail 'SUBDIRS = gl build-aux lib find xargs locate doc po m4 gnulib-tests' \
                     'SUBDIRS = gl build-aux lib find xargs'
    substituteInPlace Makefile.in \
      --replace-fail 'built_programs = find xargs frcode locate updatedb' \
                     'built_programs = find xargs'

    # fork() is hidden in the EH profiles (__wasm_exception_handling__) and the
    # symbol isn't in libc.a — same as git. Reuse git's wasix-compat shim: a
    # unistd.h that declares fork + a proc.c implementing it via __wasi_proc_fork.
    # TODO: lift wasix-compat into shared overlay infra (git + findutils both use it).
    mkdir -p wasix-compat
    cp ${../gitMinimal/wasix-compat/unistd.h} wasix-compat/unistd.h
    cp ${../gitMinimal/wasix-compat/proc.c} wasix-compat/proc.c
  '';
  # Build the shim lib, then put it on the include/link path with ABSOLUTE paths
  # ($PWD): findutils compiles in subdirs (find/, xargs/, gl/), so a relative
  # -Iwasix-compat wouldn't resolve (git got away with it by compiling in the root).
  preConfigure = ''
    export ac_cv_func_getgroups=yes
    export ac_cv_func_fork=yes
    export ac_cv_func_vfork=yes
    $CC -c wasix-compat/proc.c -o wasix-compat/proc.o
    $AR rcs wasix-compat/libwasix-compat.a wasix-compat/proc.o
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE-} -I$PWD/wasix-compat"
    export NIX_LDFLAGS="''${NIX_LDFLAGS-} -L$PWD/wasix-compat -lwasix-compat"
  '';
  overrideAttrs = old: {
    outputs = ["out"];
    postFixup = "";
    passthru =
      (old.passthru or {})
      // {wasmer = (old.passthru.wasmer or {}) // {entrypoint = "find";};};
    # Rename find/xargs to *.wasm (the convention allWasm collects) and asyncify
    # each so fork works at runtime. The standalone pass omits --enable-eh to dodge
    # binaryen's "unexpected expr type" abort, exactly as git's pass does.
    postInstall = helpers.mergeScript [
      (old.postInstall or "")
      ''
        for prog in find xargs; do
          if [ -f "$out/bin/$prog" ]; then
            mv "$out/bin/$prog" "$out/bin/$prog.wasm"
            ${foundation.binaryen}/bin/wasm-opt --asyncify -O2 \
              "$out/bin/$prog.wasm" -o "$out/bin/$prog.wasm"
          fi
        done
      ''
    ];
  };
} (prev.findutils.override {coreutils = final.buildPackages.coreutils;})
