{adds, ...}: {
  edited = [">=3.0.0"];
  forVersion = {floorPatch, ...}: {
    patches = [floorPatch];
    adds = [adds.libc];
  };
}
