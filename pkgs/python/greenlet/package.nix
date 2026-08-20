# greenlet for wasix. Upstream slp_platformselect.h has no wasm32 branch, leaving
# slp_switch undefined; the patch adds a stack switch over the wasm __stack_pointer
# and wasix_context_switch(), ported from the wasix-org/greenlet fork.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.greenlet {
  patches = [./patches/greenlet-wasm-switch.patch];
  passthru.wasinix.checks.captured.broken = "cross-thread context access traps in _Unwind_RaiseException";
  # the mod_* functions are 1-arg but bound METH_NOARGS, so wasm's typed function
  # tables trap at the call ("indirect call type mismatch")
  postPatch = ''
    substituteInPlace src/greenlet/PyModule.cpp \
      --replace-fail "(PyObject* UNUSED(module))" "(PyObject* UNUSED(module), PyObject* UNUSED(_noargs))"
    substituteInPlace src/greenlet/PyGreenlet.cpp \
      --replace-fail "green_getstate(PyGreenlet* self)" "green_getstate(PyGreenlet* self, PyObject* UNUSED(_noargs))"
  '';
}
