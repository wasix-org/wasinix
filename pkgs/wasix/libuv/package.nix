# libuv for wasix. Ported from the wasix-org build-scripts patch set, rebased
# onto 1.52.1; the current wasix-libc has chown/setgroups/recvmsg/sendmsg, so
# those reference patches are dropped. autogen.sh regenerates configure from
# the patched configure.ac/Makefile.am.
{exposeExtendedPackage}:
exposeExtendedPackage {
  # no emulated check: patch 0011 makes uv_spawn return UV_ENOSYS under
  # __wasi__ on every profile (fork itself is undeclared only under Wasm-EH,
  # not on off; WASIX-TODO.md); the library doesn't otherwise need fork().
  doCheck = false;
  # doCheck above composes after check-output.nix's wrapper reads
  # old.doCheck, so it's invisible there and a check output still gets
  # built. wasixCheckPrebuild skips the prebuild directly instead: without
  # it, `make check TESTS=` still builds test-fs-copyfile.c, which includes
  # the Windows-only direct.h unconditionally and fails to compile.
  wasixCheckPrebuild = ":";
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
