# libgit2-sys: configure WASI emulation libraries, disable unavailable process
# spawning, and keep llhttp's JavaScript callback ABI out of WASI builds.
{...}: {
  edited = [">=0.18.3"];
  stock = ["<0.18.3"];
}
