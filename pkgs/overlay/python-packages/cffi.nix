# cffi for wasix. cffi's _cffi_backend.c only enables libffi's ffi_closure_alloc on a few known
# platforms; on plain wasm32-wasi it falls back to a mmap+mprotect executable-memory closure,
# which wasix can't do. The patch adds a `__wasi__` branch that uses ffi_closure_alloc (provided
# by our libffi fork). Verbatim from build-scripts (Use-libffi-ffi_closure_alloc-on-WASIX).
{pyprev, ...}:
pyprev.cffi.overrideAttrs (old: {
  patches = (old.patches or []) ++ [./patches/cffi-ffi-closure-wasix.patch];
})
