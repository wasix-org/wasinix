# gix-fs: use WASIX std's path-typed symlink extension before upstream gained
# a target_os = "wasi" implementation in 0.21.1. The 0.15 floor is the same
# three edits against the older tree; versions between the two floors are
# unvetted rather than stock.
{...}: {
  edited = ["=0.15.0" ">=0.19.2, <0.21.1"];
  stock = [">=0.21.1"];
}
