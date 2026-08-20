# wasi-libc declares its own two-argument opendirat in the public namespace and
# gnulib carries a four-argument one, so backupfile.c sees conflicting
# declarations. gnulib's copy is the one that moves (WASIX-TODO.md).
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/wasi-opendirat.patch];
  # The autotest suite depends on POSIX permissions, sparse files, and symlinks.
  doCheck = false;
  # tar spawns its compression programs with fork, which the off profile
  # asyncifies for; binaryen cannot asyncify the EH instructions the others
  # emit.
  passthru.wasix.supportedProfiles = ["off"];
  passthru.wasix.smokeTest = false;
  # AC_TYPE_GETGROUPS is a run test, so a cross build takes its historic int
  # fallback, and gnulib's definition then disagrees with its own gid_t header.
  configureFlags = ["ac_cv_type_getgroups=gid_t"];
}
prev.gnutar
