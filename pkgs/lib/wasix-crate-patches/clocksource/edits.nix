{
  helpers,
  lib,
  ...
}: {
  edited = [">=0.8.3"];
  forVersion = {floorPatch, ...}: {
    patches = lib.optional (floorPatch != null) floorPatch;
    patchPhase = helpers.addFile ./wasi.rs "src/sys/wasi.rs";
  };
}
