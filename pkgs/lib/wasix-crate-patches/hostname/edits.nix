{
  helpers,
  lib,
  ...
}: {
  edited = [">=0.4.2"];
  forVersion = {floorPatch, ...}: {
    patches = lib.optional (floorPatch != null) floorPatch;
    patchPhase = helpers.addFile ./wasi.rs "src/wasi.rs";
  };
}
