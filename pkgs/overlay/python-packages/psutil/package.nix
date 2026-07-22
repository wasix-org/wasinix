# psutil for wasix. The patch makes the linux backend compile (the sysroot has
# no linux/ uapi headers, mntent, utmpx, sched_{get,set}affinity or sysinfo(),
# and libc spells getifaddrs getif_addrs) and lets `import psutil` past the
# platform gate, which otherwise raises on any sys.platform it does not know.
# It also needs the wasix cpython's gaps: no resource module, no socket
# AF_PACKET/AF_UNIX.
#
# What the module can then DO is limited by wasix having no /proc: cpu_count()
# answers (sysconf), everything reading /proc (Process, cpu_times,
# virtual_memory, pids, boot_time) raises, and users() is a stub. Worth
# shipping anyway: plenty of wheels import psutil unconditionally and only call
# it on demand. See tests/basic.nix for the contract.
#
# The limited API goes off for the same reason as tornado's: an abi3 wheel
# carries one cp36-abi3 filename for a .so built per interpreter, which the
# per-version registry sees as colliding filenames with differing bytes.
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  wheels = import ../lib/wheels.nix {inherit lib;};
in
  wheels.onlyOnWasix pyprev.psutil (
    helpers.libTweaks {
      patches = [./patches/psutil-wasix.patch];
      postPatch = ''
        substituteInPlace setup.py \
          --replace-fail 'if setuptools and CP36_PLUS and (MACOS or LINUX) and not Py_GIL_DISABLED:' \
                         'if False:'
      '';
    }
    pyprev.psutil
  )
