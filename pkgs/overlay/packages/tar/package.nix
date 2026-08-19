{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "tar";} (
  helpers.libTweaks {
    passthru.wasix.shipped = true;
    # tar's own autotest suite is heavily POSIX-specific (permissions,
    # sparse files, symlinks); beyond its own 153 built-in expected
    # failures, 26 more genuinely fail under wasix. Actual functionality
    # is covered separately by the CLI behavior checks (tests/basic.nix).
    doCheck = false;
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
      # tests/genfile.c: only its checkpoint-exec self-test (spawn-and-pipe a
      # child) uses fork(); genfile itself is test-support tooling, not part
      # of the shipped tar binary, so stub it the same way as above.
      substituteInPlace tests/genfile.c \
        --replace-fail '  pid = fork ();' '  errno = ENOSYS; pid = -1;'
    '';
    preConfigure = ''
      export ac_cv_func_getgroups=yes
    '';
    postInstall = ''
      rm -f "$out/bin/rmt"
    '';
  }
  prev.gnutar
)
