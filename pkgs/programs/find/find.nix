{ lib, toolchain, findutils, buildPackages, ... }:
((findutils.override {
  # findutils injects coreutils paths into scripts at build time; on WASIX this
  # must come from the build platform package set.
  coreutils = buildPackages.coreutils;
}).overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    # WASIX has no mount table API that gnulib's mountlist probe supports.
    # Keep configure non-fatal so `find` itself can still be built.
    substituteInPlace configure \
      --replace-fail 'as_fn_error $? "could not determine how to read list of mounted file systems" "$LINENO" 5' \
                     'printf "%s\n" "configure: WARNING: could not determine how to read list of mounted file systems; continuing without mountlist support" >&2; ac_list_mounted_fs=found'
    substituteInPlace gl/lib/mountlist.c \
      --replace-fail 'struct mount_entry *mount_list;' \
                     'struct mount_entry *mount_list = NULL;'
    # Rename gnulib's internal 4-arg opendirat helper to avoid colliding
    # with WASIX libc's 2-arg opendirat symbol.
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
    substituteInPlace Makefile.in \
      --replace-fail 'SUBDIRS = gl build-aux lib find xargs locate doc po m4 gnulib-tests' \
                     'SUBDIRS = gl build-aux lib find'
    substituteInPlace Makefile.in \
      --replace-fail 'built_programs = find xargs frcode locate updatedb' \
                     'built_programs = find'
    substituteInPlace find/exec.c \
      --replace-fail '  child_pid = fork ();' '  errno = ENOSYS; child_pid = -1;'
  '';
  preConfigure = (old.preConfigure or "") + ''
    ${toolchain.commonPreConfigure}
    # WASIX libc provides getgroups(); forcing this avoids a gnulib fallback
    # definition with a mismatched prototype for this target.
    export ac_cv_func_getgroups=yes
    export ac_cv_func_fork=no
    export ac_cv_func_vfork=no
  '';
  configureFlags = (old.configureFlags or [ ]) ++ [
    "--host=${toolchain.host}"
  ];
  outputs = [ "out" ];
  hardeningDisable = [ "all" ];
  postInstall = ''
    if [ -f "$out/bin/find" ]; then
      mv "$out/bin/find" "$out/bin/find.wasm"
    fi
  '';
  postFixup = "";
}))
