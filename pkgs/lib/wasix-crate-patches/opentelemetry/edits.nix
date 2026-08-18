# 0.17 gates its clock on bare target_arch = "wasm32", so a wasix build takes the
# browser path and panics inside js_sys::Date on the first timestamp; browserWasm
# narrows it. 0.18 through 0.20 do not call js_sys at all and 0.21 onwards gates
# on target_os, so the rest of the line needs nothing.
{rewriters, ...}: {
  edited = ["=0.17.0"];
  stock = ["<0.17.0" ">0.17.0"];
  forVersion = {...}: {
    patchPhase = "${rewriters.browserWasm}";
  };
}
