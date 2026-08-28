# simd-adler32 0.3.7 selects its wasm SIMD implementation in no_std builds
# but refers to std there. Upstream 0.3.8 uses core for the same transmute.
_: {
  edited = ["=0.3.7"];
  stock = [">=0.3.8"];
}
