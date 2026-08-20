# pandas for wasix. pandas/meson.build takes its numpy include dir from the BUILD python's
# numpy.get_include() → native headers (NPY_SIZEOF_LONG=8) mismatching the wasm numpy (=4),
# so its cython buffers fail to import ("Buffer dtype mismatch"). Point it at the cross numpy.
{
  pyfinal,
  pyprev,
  wasixPython,
  lib,
  helpers,
  ...
}: let
  crossNumpyInc = "${wasixPython.pkgs.numpy}/lib/${wasixPython.libPrefix}/site-packages/numpy/_core/include";
  # 3.0 spells its numpy build pin differently and carries a usable version;
  # everything below needs both corrected.
  pre3 = lib.versionOlder pyprev.pandas.version "3";
  # 2.2 pins its build tools exactly (meson==1.2.1, Cython~=3.0.5); 2.3 already
  # relaxed to ranges our set satisfies. Relax the exact pins to ours.
  pinnedBuildTools = lib.versionOlder pyprev.pandas.version "2.3";
in
  # wasm build only: a native pandas must keep its own np.get_include().
  helpers.extendPackage pyprev.pandas {
    # nixpkgs leaves pandas' suite off; opt in, running from the installed
    # wheel (the source tree lacks the compiled extensions). Replaces the
    # stashed check inputs: nixpkgs' list carries an optional-IO test matrix
    # (pyqt5, numba, s3fs...) absent on wasix; the tests importorskip those.
    passthru = old:
      old
      // {
        wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.hypothesis pyfinal.pytest-xdist];
        wasinix =
          (old.wasinix or {})
          // {
            checks.captured = {
              install = true;
              # 174k tests under emulation; the default is too short.
              timeout = 7200;
            };
          };
      };
    # Replaces nixpkgs' preCheck: its `cd $out/site-packages/pandas` breaks
    # in the run-only check derivation, where $out is unwritten. Resolve the
    # installed copy off the guest PYTHONPATH and cd into the package so its
    # shipped conftest.py registers --no-strict-data-files.
    preCheck = _: ''
      export HOME=$TMPDIR
      _site=$(echo "$PYTHONPATH" | tr ':' '\n' | grep -m1 -- '-pandas-.*site-packages$')
      cd "$_site/pandas"
      export enabledTestPaths="tests"
    '';
    # nixpkgs' flags already pass --no-strict-data-files; lists append, so
    # it must not repeat here
    pytestFlags = [
      # nixpkgs' flags pass --numprocesses=4; -n 0 (appended, so it wins)
      # keeps the run in one guest
      "-n"
      "0"
      # pandas' flags write junit at the rootdir, here inside /nix/store;
      # appended, so this wins
      "--junitxml=/home/tmp/pandas-junit.xml"
      # the suite runs -W error and this pytest deprecates iterator
      # parametrization; upstream, identical natively
      "-W"
      "ignore::pytest.PytestRemovedIn10Warning"
      "--deselect=tests/indexes/interval/test_interval_tree.py::TestIntervalTree::test_inf_bound_infinite_recursion"
      "--deselect=tests/indexing/interval/test_interval.py::TestIntervalIndexInsideMultiIndex::test_reindex_behavior_with_interval_index"
      "--deselect=tests/indexing/interval/test_interval_new.py::test_repeating_interval_index_with_infs"
    ];
    # network-marked tests fetch over the internet. A mark, not "-m": the
    # hook space-splits pytestFlags entries.
    disabledTestMarks = ["network"];
    # needs a system clipboard; errors at setup rather than skipping
    disabledTestPaths = ["tests/io/test_clipboard.py"];
    # multi_thread: the threaded parser tests take the interpreter down
    # the interval/inf tests are upstream strict xfails (GH 23440) that pass here
    # test_unique_bad_unicode: WASIX-TODO.md
    disabledTests = [
      "multi_thread"
      "test_inf_bound_infinite_recursion"
      "test_repeating_interval_index_with_infs"
      "test_reindex_behavior_with_interval_index"
      "test_unique_bad_unicode"
    ];
    # lib.const on <3: nixpkgs' postPatch relaxes a "numpy>=2.0.0" build pin
    # that only 3.x spells that way, with --replace-fail, so on a 2.x source
    # the miss is fatal. Replace the phase rather than appending to it.
    postPatch = let
      ours =
        ''
          substituteInPlace pandas/meson.build \
            --replace-fail "incdir = os.path.relpath(np.get_include())" "incdir = os.path.relpath('${crossNumpyInc}')" \
            --replace-fail "incdir = np.get_include()" "incdir = '${crossNumpyInc}'"
        ''
        + lib.optionalString pre3 ''
          # nixpkgs' src postFetch seds ITS OWN version into _version.py's
          # git_refnames, and src.override re-points the download without
          # re-running it, so a rebased tarball arrives stamped with the
          # current version and versioneer reports that. generate_version.py
          # prefers an importable _version_meson over versioneer, so state the
          # version here instead of depending on that sed.
          printf '__version__ = "%s"\n__git_version__ = "unknown"\n' \
            '${pyprev.pandas.version}' > _version_meson.py
        ''
        + lib.optionalString pinnedBuildTools ''
          substituteInPlace pyproject.toml \
            --replace-fail 'meson-python==0.13.1' 'meson-python' \
            --replace-fail 'meson==1.2.1' 'meson' \
            --replace-fail 'Cython~=3.0.5' 'Cython'
        '';
    in
      if pre3
      then lib.const ours
      else ours;
  }
