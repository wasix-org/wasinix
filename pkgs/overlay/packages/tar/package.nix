{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "tar";} (
  helpers.libTweaks {
    configureFlags = [
      "--disable-rmt"
      # Keep archive compression support intentionally narrow for now.
      "--with-gzip=gzip"
    ];
    postPatch = ''
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
    preConfigure = ''
      export ac_cv_func_getgroups=yes
    '';
    overrideAttrs = old: {
      postInstall =
        (old.postInstall or "")
        + ''
          rm -f "$out/bin/rmt"
        '';
    };
  }
  prev.gnutar
)
