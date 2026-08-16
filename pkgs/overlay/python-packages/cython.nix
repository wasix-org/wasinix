{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The runner uses a process pool above one worker; WASIX has no process semaphores.
  preCheck = ''
    export NIX_BUILD_CORES=1
  '';
}
pyprev.cython
