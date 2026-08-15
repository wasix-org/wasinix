{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  preCheck = ''
    rm -r lmdb
  '';
  passthru.wasix.emulatedCheck.broken = "POSIX advisory record locking is not implemented";
}
pyprev.lmdb
