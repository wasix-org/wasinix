# psutil for wasix. The patch makes the linux backend compile (no linux/ uapi
# headers, mntent, utmpx, sched_*affinity or sysinfo()) and gets `import psutil`
# past the platform gate. Without /proc most calls raise; see tests/basic.nix.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/psutil-wasix.patch];
  # limited API off: an abi3 wheel carries one cp36-abi3 filename for a .so built
  # per interpreter, which the per-version registry sees as colliding files.
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'if setuptools and CP36_PLUS and (MACOS or LINUX) and not Py_GIL_DISABLED:' \
                     'if False:'
  '';
}
pyprev.psutil
