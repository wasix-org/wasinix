# The abseil protobuf 29 pins; later releases carry the patch below upstream.
{exposeExtendedPackage}:
exposeExtendedPackage {
  # poison.cc declares `data` inside the sanitizer/mmap/win32 branches and reads
  # it after the #endif, so on a target in none of them clang reports "use of
  # undeclared identifier 'data'". ABSL_HAVE_MMAP keys off __EMSCRIPTEN__, which
  # a wasi target does not define, hence the fallthrough.
  patches = [
    ./abseil-wasi-mmap-poison.patch
  ];
}
