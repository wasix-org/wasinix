# tornado for wasix. Its speedups.c is built abi3 with a hardcoded cp39 floor
# (Py_LIMITED_API 0x03090000 + bdist_wheel py_limited_api=cp39), so every
# interpreter emits the same tornado-*-cp39-abi3 filename with a
# build-python-specific .so -> the per-version registry sees colliding
# filenames with differing bytes. Disable the limited API so it builds a
# normal cpXY-cpXY wheel per interpreter (distinct filenames), matching every
# other C-extension wheel here.
#
# 6.5 gates that on can_use_limited_api; 6.4 instead sets py_limited_api on the
# extension and forces a cp38-abi3 tag from a bdist_wheel subclass, so an older
# release needs whichever of the two it actually uses turned off.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = _:
    if (pyprev.tornado.passthru.wasix.historySpec or null) == null
    then ''
      substituteInPlace setup.py \
        --replace-fail 'can_use_limited_api = not sysconfig.get_config_var("Py_GIL_DISABLED")' \
                       'can_use_limited_api = False'
    ''
    else ''
      sed -i -e 's/can_use_limited_api = .*/can_use_limited_api = False/' \
             -e 's/py_limited_api=True/py_limited_api=False/' \
             -e '/define_macros=\[("Py_LIMITED_API"/d' \
             -e 's/^if wheel is not None:/if False:/' setup.py
    '';
  # process/autoreload spawn subprocesses in-guest (WASIX-TODO.md). The
  # remaining failures are wasix socket-semantics gaps, kept visible via
  # expectFail rather than deselected.
  disabledTestPaths = ["tornado/test/process_test.py" "tornado/test/autoreload_test.py"];
  passthru.wasix.emulatedCheck.expectFail = "wasix socket-semantics gaps: client timeouts never fire and iostream/tcpserver fd behaviour differs; ~23 failures out of ~1300";
}
pyprev.tornado
