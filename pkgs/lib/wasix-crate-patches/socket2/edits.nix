# socket2: version-pinned wasi backends for Hyper 0.14's 0.5.10 and the 0.6.x
# line. Support was absorbed upstream at 0.6.3, so newer 0.6 releases are stock.
# Keep unseen post-0.5.10 0.5.x releases uncovered so they fail for a fresh port.
{...}: {
  edited = ["=0.5.10" ">=0.6.0, <0.6.3"];
  stock = [">=0.6.3" "<0.5.10"];
}
