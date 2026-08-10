# h2: 0.3.21 needs the fork build the overlay registry serves; the 0.3 releases
# around it and the whole 0.4 line build stock (verified on 0.4).
{...}: {
  edited = ["=0.3.21"];
  stock = ["<0.3.21" ">0.3.21"];
}
