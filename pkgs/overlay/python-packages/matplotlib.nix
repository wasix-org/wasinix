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
  (helpers.linkInputs (helpers.dropInputsByNameInfix ["ffmpeg"])
    // {
      patches = _: [];
      mesonFlags = fs:
        builtins.filter
        (f: lib.versionAtLeast pyprev.matplotlib.version "3.11" || !lib.hasInfix "system-libraqm" f)
        (
          if fs == null
          then []
          else fs
        );
      postPatch = ''
        sed -i -E 's/^( *)([A-Za-z_]+)->get_(height|width)\(\)( \* 4)?,$/\1static_cast<py::ssize_t>(\2->get_\3()\4),/' \
          src/_backend_agg_wrapper.cpp
        grep -q 'static_cast<py::ssize_t>' src/_backend_agg_wrapper.cpp
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
        ${final.buildPackages.coreutils}/bin/cp -r "$_site/matplotlib" "$NIX_BUILD_TOP/matplotlib"
        ${final.buildPackages.coreutils}/bin/chmod -R u+w "$NIX_BUILD_TOP/matplotlib"
        while read -r _path; do
          ${final.buildPackages.coreutils}/bin/mkdir -p "$NIX_BUILD_TOP/$(${final.buildPackages.coreutils}/bin/dirname "$_path")"
          ${final.buildPackages.coreutils}/bin/cp -r "$_source/lib/$_path" "$NIX_BUILD_TOP/$_path"
        done < <(${final.buildPackages.findutils}/bin/find "$_source/lib" -name baseline_images -printf '%P\n')
        for _font in mpltest.ttf cmr10.pfb Courier10PitchBT-Bold.pfb; do
          _source_font="$(${final.buildPackages.findutils}/bin/find "$_source/lib/matplotlib/tests" -name "$_font" -print -quit)"
          [ -n "$_source_font" ] || exit 1
          ${final.buildPackages.coreutils}/bin/cp "$_source_font" "$NIX_BUILD_TOP/matplotlib/tests/"
        done
        export PYTHONPATH="$NIX_BUILD_TOP:$PYTHONPATH"
        cd "$NIX_BUILD_TOP/matplotlib"
      '';
    })
  (pyprev.matplotlib.override {
    enableTk = false;
    qhull = qhullR;
  })
