# find + xargs. Both fork (find -exec, xargs spawns), so they are
# asyncified at link (WASM_OPT_FLAGS below). coreutils is pinned to the
# build platform (findutils bakes its paths into scripts).
# locate/frcode/updatedb are dropped: they need a runtime database, useless
# on wasm. Ships as one webc with find + xargs (entrypoint find).
{
  exposePackage,
  extendPackage,
  package,
  packages,
}:
exposePackage (
  extendPackage (package.override {coreutils = packages.sameProfile.buildPackages.coreutils;}) {
    passthru.wasinix.shipped = true;
    # fork() needs asyncified binaries. wasixcc only asyncifies in the off
    # profile on its own; these extra wasm-opt flags apply the pass here too.
    env.WASIXCC_WASM_OPT_FLAGS = "--asyncify:-O2";

    postPatch = ''
      substituteInPlace configure \
        --replace-fail 'printf "%s\n" "#define MOUNTED_NOT_PORTED 1" >>confdefs.h' \
                       'ac_list_mounted_fs=found'
      # wasix-libc is musl, but gnulib gates its musl branch (nl_langinfo_l with
      # NL_LOCALE_NAME) and the <langinfo.h> include on __linux__, so wasm32-wasi
      # falls through to the "Please port gnulib getlocalename_l-unsafe.c" #error.
      substituteInPlace gl/lib/getlocalename_l-unsafe.c \
        --replace-fail '(defined __linux__ && HAVE_LANGINFO_H)' \
                       '((defined __linux__ || defined __wasi__) && HAVE_LANGINFO_H)' \
        --replace-fail '#elif defined __linux__ && HAVE_LANGINFO_H && defined NL_LOCALE_NAME' \
                       '#elif (defined __linux__ || defined __wasi__) && HAVE_LANGINFO_H && defined NL_LOCALE_NAME'
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
      # symbol isn't in libc.a, same as git. Reuse git's wasix-compat shim: a
      # unistd.h that declares fork + a proc.c implementing it via __wasi_proc_fork.
      # TODO: lift wasix-compat into shared overlay infra (git + findutils both use it).
      mkdir -p wasix-compat
      cp ${../git/wasix-compat/unistd.h} wasix-compat/unistd.h
      cp ${../git/wasix-compat/proc.c} wasix-compat/proc.c
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
    outputs = _: ["out"];
    postFixup = _: "";
    passthru.wasmer = {
      name = "find";
      entrypoint = "find";
    };
    # Rename find/xargs to *.wasm (one webc command per bin/*.wasm).
    postInstall = ''
      for prog in find xargs; do
        if [ -f "$out/bin/$prog" ]; then
          mv "$out/bin/$prog" "$out/bin/$prog.wasm"
        fi
      done
    '';
  }
)
