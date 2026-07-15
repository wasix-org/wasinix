# matplotlib for wasix.
# - enableTk pulls tk → X11 (no cross-build); force the headless Agg build.
# - drop ffmpeg-headless (movie-writer optional; its closure doesn't cross-build).
# - alias -lqhull_r → the static libqhullstatic_r.a the cross build actually installs.
# - the overlay carried matplotlib-agg-cast-wasm.patch (from the 3.10.x data
#   stack) to cast wasm32-narrowing dimensions; it's stale for 3.11.0 (the
#   RendererAgg cast it added is now upstream). Drop it and cast the buffer
#   3.11.0 still leaves un-cast (BufferRegion) via postPatch instead.
{
  pyprev,
  final,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
  qhullR =
    helpers.libTweaks {
      postInstall = ''
        ln -sf libqhullstatic_r.a "$out/lib/libqhull_r.a"
      '';
    }
    final.qhull;
in
  helpers.libTweaks
  (wheels.dropInputsByName ["ffmpeg"]
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
