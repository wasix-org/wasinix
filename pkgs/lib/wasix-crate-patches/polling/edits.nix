# polling: WASIX epoll backend. The target is not Unix to rustc, so the
# upstream portable poll backend and its rustix pipe notifier are unavailable.
{adds, ...}: {
  edited = [">=3.11.0, <4.0.0"];
  stock = ["<3.11.0"];
  forVersion = {floorPatch, ...}: {
    patches = [floorPatch];
    patchPhase = ''
      cp --no-preserve=mode ${./wasix.rs} src/wasix.rs
    '';
    adds = [adds.wasix];
  };
}
