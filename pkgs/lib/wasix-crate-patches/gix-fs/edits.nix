# gix-fs: use WASIX std's path-typed symlink extension before upstream gained
# a target_os = "wasi" implementation in 0.21.1.
{...}: {
  edited = [">=0.19.2, <0.21.1"];
  stock = ["<0.19.2" ">=0.21.1"];
}
