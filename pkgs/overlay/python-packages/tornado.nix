# tornado for wasix. Its speedups.c is built abi3 with a hardcoded cp39 floor
# (Py_LIMITED_API 0x03090000 + bdist_wheel py_limited_api=cp39), so every
# interpreter emits the same tornado-*-cp39-abi3 filename with a
# build-python-specific .so -> the per-version registry sees colliding
# filenames with differing bytes. Disable the limited API so it builds a
# normal cpXY-cpXY wheel per interpreter (distinct filenames), matching every
# other C-extension wheel here.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'can_use_limited_api = not sysconfig.get_config_var("Py_GIL_DISABLED")' \
                     'can_use_limited_api = False'
  '';
}
pyprev.tornado
