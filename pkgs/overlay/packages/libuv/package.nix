# libuv for wasix. Ported from the wasix-org build-scripts patch set, rebased
# onto 1.52.1; the current wasix-libc has chown/setgroups/recvmsg/sendmsg, so
# those reference patches are dropped. autogen.sh regenerates configure from
# the patched configure.ac/Makefile.am.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [
    ./patches/libuv-0001-add-wasix-to-autotools.patch
    ./patches/libuv-0002-Disable-slave-tty-detection-with-wasix.patch
    ./patches/libuv-0003-Disable-thread-names-with-wasix.patch
    ./patches/libuv-0004-Disable-use-of-msghdr-with-wasix.patch
    ./patches/libuv-0006-Disable-statfs-with-wasix.patch
    ./patches/libuv-0008-disable-thread-priorities-with-wasix.patch
    ./patches/libuv-0009-Include-posix-header-when-targeting-wasix.patch
    ./patches/libuv-0010-Fix-WASIX-thread-spawning-erroring-out-with-a-signat.patch
    ./patches/libuv-0011-disable-fork-spawn-with-wasix.patch
    ./patches/libuv-0012-no-dlfcn-with-wasix.patch
    ./patches/libuv-0013-wasix-ifaddrs-names-no-if_index.patch
  ];
}
prev.libuv
