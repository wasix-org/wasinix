# The 3.1 unix path parser is gated on `target_family = "wasm"` plus an opt-in
# feature, so a wasm target otherwise gets no `ParseDot` impl at all. Enabling
# it by default is upstream's own switch; 4.0 drops the feature gate itself.
{...}: {
  edited = [">=3.1.1, <4.0.0"];
  stock = ["<3.1.1" ">=4.0.0"];
}
