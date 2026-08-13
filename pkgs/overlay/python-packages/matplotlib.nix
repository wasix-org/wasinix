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
      '';
    })
  (pyprev.matplotlib.override {
    enableTk = false;
    qhull = qhullR;
  })
