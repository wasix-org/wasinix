{
  exposeExtendedPackage,
  packages,
  package,
  lib,
}: let
  isHistory = (package.passthru.wasix.historySpec or null) != null;
in
  exposeExtendedPackage {
    patches = old:
      lib.optionals (old != null) old
      ++ lib.optionals (!isHistory) [./patches/cython-wasix-builtin-compatibility.patch];
    passthru.wasixDeclaredCheckInputs = [packages.sameProfile.numpy packages.sameProfile.setuptools];
    passthru.wasinix.checks.captured = {
      shards = 8;
      timeout = 1200;
      tags = ["slow-tests"];
    };
    installCheckPhase = _: ''
      export HOME="$NIX_BUILD_TOP"
      ${packages.sameProfile.python.interpreter} runtests.py -j1 --no-code-style --cython-only --no-refnanny \
        --shard_count "$WASIX_CHECK_SHARD_COUNT" --shard_num "$WASIX_CHECK_SHARD_NUM"
    '';
  }
