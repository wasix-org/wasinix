# matplotlib for wasix: enableTk pulls tk -> X11, so force the headless Agg build;
# drop ffmpeg-headless (optional movie writers, closure doesn't cross-build); alias
# -lqhull_r to the static libqhullstatic_r.a the cross build installs; postPatch
# casts the BufferRegion dimensions wasm32 narrows, replacing the inherited patches.
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
      postPatch = ''
        substituteInPlace src/_backend_agg_wrapper.cpp \
          --replace-fail "buffer->get_height()," "static_cast<py::ssize_t>(buffer->get_height())," \
          --replace-fail "buffer->get_width()," "static_cast<py::ssize_t>(buffer->get_width())," \
          --replace-fail "buffer->get_width() * 4," "static_cast<py::ssize_t>(buffer->get_width() * 4),"
      '';
    })
  (pyprev.matplotlib.override {
    enableTk = false;
    qhull = qhullR;
  })
