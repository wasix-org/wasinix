# filetime: std::fs::Metadata exposes timestamps on WASIX, while the generic
# wasm backend leaves all timestamp reads unimplemented.
{...}: {
  edited = [">=0.2.27, <0.3.0"];
  stock = ["<0.2.27"];
}
