# async-tar only uses async-std's stable default APIs. Its unconditional
# `unstable` feature also enables async-process, even though tar creation never
# spawns a child; avoid that unsupported and unused dependency.
_: {
  edited = ["=0.5.1"];
  stock = ["<0.5.1"];
}
