# wasi-libc declares its own two-argument opendirat in the public namespace and
# gnulib carries a four-argument one, so backupfile.c sees conflicting
# declarations. gnulib's copy is the one that moves (WASIX-TODO.md).
{
  exposePackage,
  extendPackage,
  package,
  wasmRename,
}:
exposePackage (
  wasmRename {
    wasmName = "tar";
    posixAlias = true;
  } (
    extendPackage package {
      patches = [./patches/wasi-opendirat.patch];
      # The autotest suite depends on POSIX permissions, sparse files, and symlinks.
      doCheck = false;
      passthru.wasinix.shipped = true;
      # tar spawns its compression programs with fork, which the off profile
      # asyncifies for; binaryen cannot asyncify the EH instructions the others
      # emit.
      passthru.wasix.supportedProfiles = ["off"];
      passthru.wasmer.name = "tar";
      configureFlags = [
        # AC_TYPE_GETGROUPS is a run test, so a cross build takes its historic int
        # fallback, and gnulib's definition then disagrees with its own gid_t header.
        "ac_cv_type_getgroups=gid_t"
        "--disable-rmt"
        "--with-gzip=gzip"
      ];
      postPatch = ''
        substituteInPlace gnu/getgroups.c \
          --replace-fail 'getgroups (_GL_UNUSED int n, _GL_UNUSED GETGROUPS_T *groups)' \
                         'getgroups (_GL_UNUSED int n, _GL_UNUSED gid_t *groups)'
        substituteInPlace lib/rtapelib.c \
          --replace-fail '    status = fork ();' '    errno = ENOSYS; status = -1;'
        substituteInPlace src/misc.c \
          --replace-fail '  pid_t p = fork ();' '  errno = ENOSYS; pid_t p = -1;'
        substituteInPlace tests/genfile.c \
          --replace-fail '  pid = fork ();' '  errno = ENOSYS; pid = -1;'
      '';
      postInstall = ''
        rm -f "$out/bin/rmt"
      '';
    }
  )
)
