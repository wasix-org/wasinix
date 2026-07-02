# python3 (CPython 3.13) for wasix: nixpkgs upstream cpython built under the wasix stdenv, with
# the overlay wasix libs auto-threading in. Ref: build-scripts' wasix-org/cpython recipe.
# tzdata is swapped to build-platform (see below); gdbm dropped (fork()). subprocess works via
# posix_spawn (wasi has no fork) — see the patch + the cache vars below.
#
# ehpic only (passthru.wasix.supportedProfiles below): dl/ctypes need the PIC sysroot.
{
  final,
  prev,
  preferredPackages,
  helpers,
  ...
}: let
  lib = prev.lib;
  # CPython minor version ("3.13"), so the postInstall symlink/scrub paths track a bump.
  pyVer = prev.python3.pythonVersion;

  # wasix build fixes for the python package set; see overlay/python-packages/.
  pythonPackageOverrides = import ../../python-packages {
    inherit lib;
    callArgs = {inherit final prev preferredPackages helpers lib;};
  };

  py =
    helpers.libTweaks {
      # Dynamic linking → import .so C-extension wheels (via enable-wasm-dynamic-linking-wasi.patch;
      # our ehpic module is already -pie, so no extra link flags).
      configureFlags = ["--enable-wasm-dynamic-linking"];

      # Autoconf cache vars: what the wasix-org/cpython config.site/configure patches would set,
      # declaratively (the build re-runs autoreconf, so a fresh probe must see these).
      env = {
        # clang 21 defaults to -std=gnu23, breaking configure's "CC name" conftest.
        ac_cv_cc_name = "clang";
        # Features wasix genuinely lacks:
        ac_cv_buggy_getaddrinfo = "no";
        ac_cv_file__dev_ptmx = "no";
        ac_cv_file__dev_ptc = "no";
        ac_cv_header_sys_resource_h = "no";
        ac_cv_header_sys_un_h = "no"; # no AF_UNIX
        ac_cv_header_netpacket_packet_h = "no";
        ac_cv_func_eventfd = "no";
        ac_cv_func_mkfifo = "no";
        ac_cv_func_mkfifoat = "no";
        ac_cv_func_mknod = "no";
        ac_cv_func_mknodat = "no";
        ac_cv_func_makedev = "no";
        ac_cv_func_fdopendir = "no";
        ax_cv_c_float_words_bigendian = "no";
        ac_cv_disable_int_conversion = "yes";
        ac_cv_func_memfd_create = "no"; # declared but the probe fails
        # In the sysroot but the cross probe defaults off; the mmap module needs both headers.
        ac_cv_header_sys_mman_h = "yes";
        ac_cv_header_sys_stat_h = "yes";
        # In libc.a but the -lm probe can't see them (libm.a is an empty stub); timegm is a GNU ext.
        ac_cv_func_acosh = "yes";
        ac_cv_func_asinh = "yes";
        ac_cv_func_atanh = "yes";
        ac_cv_func_erf = "yes";
        ac_cv_func_erfc = "yes";
        ac_cv_func_expm1 = "yes";
        ac_cv_func_log1p = "yes";
        ac_cv_func_log2 = "yes";
        ac_cv_func_timegm = "yes";
        ac_cv_func_strftime = "yes"; # probe-missed; pandas imports time.strftime at load
        # From -lwasi-emulated-process-clocks; without HAVE_CLOCK* the users link against absent definers.
        ac_cv_func_clock = "yes";
        ac_cv_func_clock_gettime = "yes";
        ac_cv_func_dup2 = "yes"; # in PIC libc.a but AC_REPLACE_FUNCS misses it → duplicate dup2
        ac_cv_func_mmap = "yes"; # emulated-mman, always linked; cross probe defaults to no
        # WASIX has symlink stat; without it os.lstat→realpath raises NotImplementedError → ctypes breaks.
        ac_cv_func_lstat = "yes";
        ac_cv_func_fstatat = "yes";
        ac_cv_func_readlink = "yes";
        ac_cv_func_readlinkat = "yes";
        # posix_spawn(p) + the subprocess pipeline (pipe/reap/fd setup/signals): in libc, but
        # probe-missed or WASI-disabled upstream. execv is needed for HAVE_EXECV (posix_spawn's
        # parse_arglist etc. gate on it, not HAVE_POSIX_SPAWN). subprocess uses os.posix_spawnp.
        ac_cv_func_posix_spawn = "yes";
        ac_cv_func_posix_spawnp = "yes";
        ac_cv_func_execv = "yes";
        ac_cv_func_pipe = "yes";
        ac_cv_func_pipe2 = "yes";
        ac_cv_func_waitpid = "yes";
        ac_cv_func_wait4 = "yes";
        ac_cv_func_fcntl = "yes";
        ac_cv_func_dup = "yes";
        ac_cv_func_dup3 = "yes";
        ac_cv_func_kill = "yes";
        ac_cv_func_sigaction = "yes";
        ac_cv_func_getpid = "yes"; # emulated-getpid; multiprocessing.pool (e.g. caio) calls it at import
        # os.uname / socket.gethostname; sqlalchemy reads them at import.
        ac_cv_func_uname = "yes";
        ac_cv_func_gethostname = "yes";
        # HAVE_SIGSET_T (posix_spawn's restore_signals) gates on these; all in libc, undetected.
        ac_cv_func_pthread_sigmask = "yes";
        ac_cv_func_sigwait = "yes";
        ac_cv_func_sigtimedwait = "yes";
        ac_cv_func_sigwaitinfo = "yes";
        # wasix has real pthreads; configure defaults WASI to clashing stubs. (NOT --enable-wasm-pthreads.)
        ac_cv_pthread = "yes";
        # clang 16+ makes implicit-decl/int-conversion hard errors → autoconf conftests fail; relax to warn.
        NIX_CFLAGS_COMPILE = "-Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -Wno-deprecated-non-prototype";
      };

      patches = [
        # ctypes.util.find_library: upstream's posix branch shells out to ldconfig/gcc (→ None on
        # wasm); resolve builtins to the main module + search the dirs for a wasm dylib.
        ./patches/ctypes-find-library-wasi.patch
        # Allow --enable-wasm-dynamic-linking on WASI (upstream errors "not implemented yet").
        ./patches/enable-wasm-dynamic-linking-wasi.patch
        # subprocess on wasi: drop wasi from _can_fork_exec's exclusion and route it through
        # posix_spawn (no fork). From the wasix-org/cpython fork.
        ./patches/subprocess-posix-spawn-wasi.patch
      ];

      # wasix-libc declares but doesn't implement the pty fns → cpython compiles os.openpty etc. →
      # undefined at link. Link ENOSYS stubs (survives the autoreconf re-configure). TODO: upstream.
      preBuild = ''
        cat > wasix_pty_stubs.c <<'STUBS'
        #include <errno.h>
        #include <stddef.h>
        int grantpt(int fd) { (void)fd; errno = ENOSYS; return -1; }
        int unlockpt(int fd) { (void)fd; errno = ENOSYS; return -1; }
        char *ptsname(int fd) { (void)fd; errno = ENOSYS; return NULL; }
        int openpty(int *a, int *b, char *c, const void *d, const void *e) {
          (void)a; (void)b; (void)c; (void)d; (void)e; errno = ENOSYS; return -1;
        }
        STUBS
        $CC -c wasix_pty_stubs.c -o wasix_pty_stubs.o
        export NIX_LDFLAGS="''${NIX_LDFLAGS:-} $PWD/wasix_pty_stubs.o"
      '';

      # configure's WASI block links phantom -lwasi-emulated-signal / -latomic (no such libs on
      # wasix); drop them from the Makefile. The installed sysconfig carries them too (postInstall).
      postConfigure = ''
        sed -i 's/ -lwasi-emulated-signal//g; s/ -latomic//g' Makefile
      '';

      # Point subprocess(shell=True)'s baked sh at the wasix off-profile bash (cpython bakes the
      # build-platform bash). substituteInPlace, not a .patch, because both store paths are dynamic;
      # the webc mounts it via selfMounts (it lives in a .py, which autoSelfMount doesn't scan).
      postPatch = ''
                substituteInPlace Lib/subprocess.py \
                  --replace-fail '${final.buildPackages.bashNonInteractive}/bin/sh' '${preferredPackages.bash}/bin/sh'

                # configure hardcodes py_cv_module_mmap=n/a for WASI (and regenerates from
                # configure.ac, so patching configure doesn't stick); force the mmap module via
                # Setup.local. wasix has mmap and pandas imports it at load.
                echo "mmap mmapmodule.c" >> Modules/Setup.local

                # the #else wasi hits defines my_getpagesize but leaves my_getallocationgranularity
                # undefined → link error; alias it too (wasi has getpagesize).
                substituteInPlace Modules/mmapmodule.c \
                  --replace-fail "#define my_getpagesize getpagesize" \
                    "#define my_getpagesize getpagesize
        #define my_getallocationgranularity my_getpagesize"
      '';

      # Point the dangling python/python3 symlinks at the installed .wasm, and scrub the phantom
      # -lwasi-emulated-signal/-latomic (see postConfigure) from every place an extension build reads
      # link flags (pkgconfig, _sysconfigdata, config Makefile, python-config) — else meson feeds
      # them to wasm-ld.
      postInstall = ''
        for n in python${pyVer} python3 python; do ln -sf python${pyVer}.wasm "$out/bin/$n"; done

        for f in \
          "$out"/lib/pkgconfig/python-*.pc \
          "$out"/lib/python${pyVer}/_sysconfigdata*.py \
          "$out"/lib/python${pyVer}/config-*/Makefile \
          "$out"/bin/python${pyVer}-config; do
          [ -e "$f" ] && sed -i 's/-lwasi-emulated-signal//g; s/-latomic//g' "$f"
        done
      '';

      dontCheckForBrokenSymlinks = true;

      # Allow the build-platform bash in the closure: dev-tool shebangs point at it (harmless, never
      # run under wasmer). The build-host-python guard stays.
      disallowedReferences = drf:
        builtins.filter (r: r != final.buildPackages.bashNonInteractive)
        (
          if drf == null
          then []
          else drf
        );

      # ehpic only: PIC is required for dl — the wasix sysroot ships dlfcn.h + dlopen/dlsym only
      # in its PIC variants, and ctypes + dynamic extension loading need them. Other profiles are
      # genuinely unsupported (not broken); this also makes ehpic the preferred (shipping)
      # profile. autoSelfMount mounts the store paths the wasm embeds (incl. PREFIX=$out → the
      # stdlib).
      passthru = {
        wasix.supportedProfiles = ["ehpic"];
        wasmer = {
          name = "python";
          entrypoint = "python3.13";
          autoSelfMount = true;
          # autoSelfMount only scans bin/*.wasm, so paths that live in a .py / the sysconfig are
          # missed and mounted explicitly: the wasix bash (baked into subprocess.py), and tzdata
          # (--with-tzpath bakes it into _sysconfigdata, not the .wasm — else zoneinfo raises
          # "No time zone found").
          selfMounts = [preferredPackages.bash final.buildPackages.tzdata];
        };
      };
    } (prev.python3.override {
      # Build-platform tzdata: the cross tzcode doesn't build (getresuid), and null broke the BUILD
      # python's zoneinfo (babel/hypothesis suites). zoneinfo is platform-independent; the webc mounts
      # it via selfMounts above (--with-tzpath bakes it into _sysconfigdata, not the .wasm).
      tzdata = final.buildPackages.tzdata;
      gdbm = null;
      bashNonInteractive = final.buildPackages.bashNonInteractive;
      # `self = py` makes python3.pkgs.<pkg> build against THIS python, not the unfixed python313
      # (lazy: .pkgs only, doesn't rebuild the interpreter).
      self = py;
      packageOverrides = pythonPackageOverrides;
    });
in
  py
