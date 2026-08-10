# sct: 0.7.0 needs the fork build the overlay registry serves; 0.7.1 builds
# stock (verified).
{...}: {
  edited = ["=0.7.0"];
  stock = ["<0.7.0" ">0.7.0"];
}
