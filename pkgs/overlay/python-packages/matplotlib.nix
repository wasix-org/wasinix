# matplotlib for wasix: enableTk pulls tk -> X11, so force the headless Agg build;
# drop ffmpeg-headless (optional movie writers, closure doesn't cross-build); alias
# -lqhull_r to the static libqhullstatic_r.a the cross build installs; postPatch
# casts the shape and stride dimensions wasm32 narrows, replacing the inherited
# patches; which object holds them differs by release, so match the list element.
# 3.11 added the system-libraqm meson option, so an older release aborts on the flag.
{
  pyprev,
  final,
  lib,
  helpers,
  ...
}: let
  qhullR =
    helpers.libTweaks {
      postInstall = ''
        ln -sf libqhullstatic_r.a "$out/lib/libqhull_r.a"
      '';
    }
    final.qhull;
in
  helpers.libTweaks
  (
    helpers.linkInputs (helpers.dropInputsByNameInfix ["ffmpeg"])
    // {
      passthru.wasix.emulatedCheck.shards = 8;
      patches = _: [];
      mesonFlags = fs:
        builtins.filter (
          f: lib.versionAtLeast pyprev.matplotlib.version "3.11" || !lib.hasInfix "system-libraqm" f
        ) (
          if fs == null
          then []
          else fs
        );
      postPatch = ''
        sed -i -E 's/^( *)([A-Za-z_]+)->get_(height|width)\(\)( \* 4)?,$/\1static_cast<py::ssize_t>(\2->get_\3()\4),/' \
          src/_backend_agg_wrapper.cpp
        grep -q 'static_cast<py::ssize_t>' src/_backend_agg_wrapper.cpp
        ${lib.optionalString (lib.versionAtLeast pyprev.matplotlib.version "3.11") ''
          substituteInPlace lib/matplotlib/tests/test_animation.py \
            --replace-fail \
              'elif sys.platform == "emscripten":' \
              'elif sys.platform in {"emscripten", "wasix"}:'
        ''}
        substituteInPlace lib/matplotlib/tests/test_backends_interactive.py \
          --replace-fail \
            '(["tkinter"], {"MPLBACKEND": "tkagg"}),' \
            '(["tkinter", "_tkinter"], {"MPLBACKEND": "tkagg"}),'
        substituteInPlace lib/matplotlib/tests/test_pickle.py \
          --replace-fail \
            'def test_axeswidget_interactive():' \
            $'def test_axeswidget_interactive():\n    pytest.importorskip("_tkinter")'
        ${lib.optionalString (lib.versionAtLeast pyprev.matplotlib.version "3.11") ''
          substituteInPlace lib/matplotlib/tests/test_mlab.py \
            --replace-fail \
              "sys.platform == 'emscripten'" \
              "sys.platform in {'emscripten', 'wasix'}"
        ''}
        substituteInPlace lib/matplotlib/tests/test_ticker.py \
          --replace-fail \
            'import re' \
            $'import re\nimport sys' \
          --replace-fail \
            'def test_locale_comma():' \
            $'@pytest.mark.xfail(sys.platform == "wasix", reason="wasix-libc localeconv is POSIX-only", strict=True)\ndef test_locale_comma():'
        substituteInPlace lib/matplotlib/testing/__init__.py \
          --replace-fail \
            'except (OSError, subprocess.CalledProcessError):' \
            'except (OSError, subprocess.CalledProcessError, NotImplementedError):'
      '';
      preCheck = _: ''
        _source="$PWD"
        _site=
        for _path in ''${PYTHONPATH//:/ }; do
          case "$_path" in *-matplotlib-*/lib/python*/site-packages) _site="$_path"; break ;; esac
        done
        [ -n "$_site" ] || exit 1
        ${lib.getExe' final.buildPackages.coreutils "cp"} -r "$_site/matplotlib" "$NIX_BUILD_TOP/matplotlib"
        ${lib.getExe' final.buildPackages.coreutils "chmod"} -R u+w "$NIX_BUILD_TOP/matplotlib"
        ${lib.getExe' final.buildPackages.coreutils "cp"} -r \
          "$_source/lib/matplotlib/tests/." "$NIX_BUILD_TOP/matplotlib/tests/"
        export PYTHONPATH="$NIX_BUILD_TOP:$PYTHONPATH"
        pytestFlagsArray+=("$NIX_BUILD_TOP/matplotlib/tests")
        ${lib.getExe' final.buildPackages.coreutils "mkdir"} "$NIX_BUILD_TOP/check"
        cd "$NIX_BUILD_TOP/check"
      '';
    }
  )
  (
    pyprev.matplotlib.override {
      enableTk = false;
      qhull = qhullR;
    }
  )
