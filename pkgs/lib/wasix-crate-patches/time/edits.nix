# time: the 0.1 line predates any wasi support; 0.1.44 is the fork build the
# overlay registry serves. 0.2 and 0.3 build stock (verified on 0.3).
{...}: {
  edited = ["=0.1.44"];
  stock = ["<0.1.44" ">0.1.44"];
}
