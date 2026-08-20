{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.lmdb {
  preCheck = ''
    rm -r lmdb
  '';
  passthru.wasinix.checks.captured.broken = "POSIX advisory record locking is not implemented";
}
