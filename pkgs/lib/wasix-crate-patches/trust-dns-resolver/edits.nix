# trust-dns-resolver: the floor is the fork build the overlay registry serves,
# which pins the system domain rather than reading resolv.conf. Its `hostname`
# dependency has no wasi support, so a consumer still needs that resolved.
_: {
  edited = ["=0.23.1"];
  stock = ["<0.23.1" ">0.23.1"];
}
