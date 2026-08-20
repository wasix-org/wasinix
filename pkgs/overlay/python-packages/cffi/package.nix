# cffi for wasix. On wasm32-wasi cffi's closures fall back to mmap+mprotect exec memory, which
# wasix can't do; the patch uses libffi's ffi_closure_alloc instead (from our libffi fork).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/cffi-ffi-closure-wasix.patch];
  # No suite: the tests compile C at test time, and the guest cannot exec the
  # compiler; cffi-consuming suites cover the shipped module.
  passthru.wasinix.checks.captured.install = false;
}
pyprev.cffi
