{ toolchain, gnutar, ... }:
(gnutar.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    # Rename gnulib's 4-arg opendirat helper to avoid colliding with
    # WASIX libc's 2-arg opendirat symbol.
    substituteInPlace gnu/backupfile.c \
      --replace-fail 'opendirat (dir_fd, buf, 0, pnew_fd)' 'rpl_opendirat (dir_fd, buf, 0, pnew_fd)'
    substituteInPlace gnu/opendirat.c \
      --replace-fail 'opendirat (int dir_fd, char const *dir, int extra_flags, int *pnew_fd)' \
                     'rpl_opendirat (int dir_fd, char const *dir, int extra_flags, int *pnew_fd)'
    substituteInPlace gnu/opendirat.h \
      --replace-fail 'DIR *opendirat (int, char const *, int, int *)' \
                     'DIR *rpl_opendirat (int, char const *, int, int *)'
    substituteInPlace gnu/getgroups.c \
      --replace-fail 'getgroups (_GL_UNUSED int n, _GL_UNUSED GETGROUPS_T *groups)' \
                     'getgroups (_GL_UNUSED int n, _GL_UNUSED gid_t *groups)'
    substituteInPlace lib/rtapelib.c \
      --replace-fail '    status = fork ();' '    errno = ENOSYS; status = -1;'
    substituteInPlace src/misc.c \
      --replace-fail '  pid_t p = fork ();' '  errno = ENOSYS; pid_t p = -1;'
  '';
  preConfigure = (old.preConfigure or "") + ''
    ${toolchain.commonPreConfigure}
    # WASIX libc already provides getgroups() with gid_t* signature.
    export ac_cv_func_getgroups=yes
  '';
  configureFlags = (old.configureFlags or [ ]) ++ [
    "--host=${toolchain.host}"
    "--disable-rmt"
    # Keep archive compression support intentionally narrow for now.
    "--with-gzip=gzip"
  ];
  hardeningDisable = [ "all" ];
  postInstall = (old.postInstall or "") + ''
    if [ -f "$out/bin/tar" ]; then
      mv "$out/bin/tar" "$out/bin/tar.wasm"
    fi
    rm -f "$out/bin/rmt"
  '';
}))
