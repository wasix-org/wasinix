# matplotlib for wasix.
# - enableTk pulls tk → X11 (no cross-build); force the headless Agg build.
# - agg casts unsigned dims to signed ssize_t → narrowing error on 32-bit wasm; patch adds casts.
# - drop ffmpeg-headless (movie-writer optional; its closure doesn't cross-build).
# - alias -lqhull_r → the static libqhullstatic_r.a the cross build actually installs.
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
  helpers.libTweaks (
    wheels.dropInputsByName ["ffmpeg"]
    // {patches = [./patches/matplotlib-agg-cast-wasm.patch];}
  )
  (pyprev.matplotlib.override {
    enableTk = false;
    qhull = qhullR;
  })
