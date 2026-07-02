# greenlet for wasix. Upstream slp_platformselect.h has no wasm32 branch → slp_switch undefined.
# greenlet-wasm-switch.patch adds a wasix stack switch (switch_wasm32_wasix.h, via the wasm
# __stack_pointer + wasix_context_switch()). Ported from the wasix-org/greenlet fork.
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
in
  # wasm build only: switch_wasm32_wasix.h includes wasix/context.h, so it can't compile natively.
  wheels.onlyOnWasix pyprev.greenlet (
    helpers.libTweaks {
      patches = [./patches/greenlet-wasm-switch.patch];
      # greenlet's mod_* functions are 1-arg but bound METH_NOARGS (called 2-arg); on wasm's
      # strict function-table typing that traps at call ("indirect call type mismatch"). Fix the sigs.
      postPatch = ''
        substituteInPlace src/greenlet/PyModule.cpp \
          --replace-fail "(PyObject* UNUSED(module))" "(PyObject* UNUSED(module), PyObject* UNUSED(_noargs))"
        substituteInPlace src/greenlet/PyGreenlet.cpp \
          --replace-fail "green_getstate(PyGreenlet* self)" "green_getstate(PyGreenlet* self, PyObject* UNUSED(_noargs))"
      '';
    }
    pyprev.greenlet
  )
