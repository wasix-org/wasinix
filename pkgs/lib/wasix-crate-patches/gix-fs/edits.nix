# gix-fs: use WASIX std's path-typed symlink extension before upstream gained
# a target_os = "wasi" implementation in 0.20.0 (symlink, capabilities, and
# lib are byte-identical from 0.20.0 through 0.21.1). The 0.15 floor is the
# same three edits against the older tree.
_: {
  edited = ["=0.15.0" ">=0.19.2, <0.20.0"];
  stock = [">=0.20.0"];
}
