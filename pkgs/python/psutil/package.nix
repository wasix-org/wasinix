# psutil for wasix. The patch makes the linux backend compile (no linux/ uapi
# headers, mntent, utmpx, sched_*affinity or sysinfo()) and gets `import psutil`
# past the platform gate. Without /proc most calls raise; see tests/basic.nix.
# 7.0 split the C backends into arch/linux/ and arch/posix/; before it the posix
# half lives in _psutil_posix.c and users.c reads utmp, so an older release takes
# the same edits cut against that layout.
{
  pyprev,
  lib,
  helpers,
  ...
}:
helpers.extendPackage pyprev.psutil {
  # The suite loops on a TypeError because the guest has no /proc.
  passthru.wasinix.checks.captured.install = false;
  patches =
    if lib.versionOlder pyprev.psutil.version "7"
    then [./patches/psutil-presplit-wasix.patch]
    else [./patches/psutil-wasix.patch];
  # limited API off: an abi3 wheel carries one cp36-abi3 filename for a .so built
  # per interpreter, which the per-version registry sees as colliding files. Which
  # interpreters the gate names moves between releases, so disarm what it sets.
  postPatch = ''
    sed -i -E 's/py_limited_api = \{"py_limited_api": True\}/py_limited_api = {}/g
               s/^(\s*)options = \{"bdist_wheel": \{"py_limited_api".*$/\1options = {}/' setup.py
    ! grep -q '"py_limited_api": True' setup.py
  '';
}
