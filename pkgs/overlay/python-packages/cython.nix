{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}: let
  isHistory = (pyprev.cython.passthru.wasix.historySpec or null) != null;
in
  helpers.libTweaks {
    patches = old:
      lib.optionals (old != null) old
      ++ lib.optionals (!isHistory) [./patches/cython-wasix-builtin-compatibility.patch];
    passthru.wasixDeclaredCheckInputs = [pyfinal.numpy pyfinal.setuptools];
    passthru.wasix.emulatedCheck = {
      shards = 4;
      timeout = 3600;
    };
    installCheckPhase = _: ''
      export HOME="$NIX_BUILD_TOP"
      ${pyfinal.python.interpreter} runtests.py -j1 --no-code-style --cython-only --no-refnanny \
        --shard_count "$WASIX_CHECK_SHARD_COUNT" --shard_num "$WASIX_CHECK_SHARD_NUM"
    '';
  }
  pyprev.cython
