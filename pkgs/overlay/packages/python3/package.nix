# python3 (CPython 3.13) for wasix: nixpkgs cpython built under the wasix
# stdenv, following the wasix-org/cpython recipe. tzdata comes from the build
# platform (see below), gdbm is dropped (needs fork), subprocess works via
# posix_spawn (wasi has no fork; see the patch and cache vars below).
# ehpic only: dl/ctypes need the PIC sysroot.
{
  final,
  prev,
  preferredProfilePackages,
  helpers,
  ...
}: let
  lib = prev.lib;
  pyVer = prev.python3.pythonVersion;

  pythonPackageOverrides = import ../../python-packages {
    callArgs = {inherit final prev preferredProfilePackages helpers lib;};
  };

  py =
    helpers.libTweaks {
      passthru.wasix.shipped = true;
      # Enables importing .so C-extension wheels (needs enable-wasm-dynamic-linking-wasi.patch;
      # ehpic is already -pie, so no extra link flags).
      configureFlags = ["--enable-wasm-dynamic-linking"];

      # Autoconf cache vars, equivalent to the wasix-org/cpython config.site/configure
      # patches; the build re-runs autoreconf, so fresh probes must see these.
      env = {
        # The interpreter is a wasixcc dynamic-main; C++ extension wheels are side
        # modules that dlopen into it. Pull the C++ runtime (--whole-archive -lc++
        # -lc++abi) into the main and --export-all it, so those .so's resolve libc++
        # as dynamic imports from this one shared copy (correct cross-module RTTI/EH)
        # instead of each baking in its own.
        WASIXCC_INCLUDE_CPP_SYMBOLS = "yes";
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
        # readline.pc has Requires.private: termcap with no termcap.pc, so pkg-config can't
        # resolve it and the -lreadline-only fallback misses ncurses' termcap symbols. Seed
        # PKG_CHECK_MODULES's result vars directly (both set -> pkg-config is skipped) with the
        # ncurses link added, so the module builds. readline + ncurses are already buildInputs.
        LIBREADLINE_CFLAGS = "-I${lib.getDev final.readline}/include";
        LIBREADLINE_LIBS = "-lreadline -lncurses";
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

      # wasix-libc declares but doesn't implement some libc fns → cpython compiles the callers
      # (os.openpty, the forced pwd/grp modules) → undefined at link. Link ENOSYS/no-op stubs
      # (survives the autoreconf re-configure). TODO: upstream.
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
        // pwd/grp enumeration: declared in pwd.h/grp.h, absent from libc.a. wasix has no
        // passwd/group database, so the getent iterators return nothing and end/set no-op.
        void endpwent(void) {}
        void endgrent(void) {}
        // libuuid (_uuid) locks its clock-state file with flock; declared in sys/file.h,
        // absent from libc.a. Single-process wasm needs no lock, so succeed.
        int flock(int fd, int op) { (void)fd; (void)op; return 0; }
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
      # build-platform bash).
      postPatch = ''
                substituteInPlace Lib/subprocess.py \
                  --replace-fail '${final.buildPackages.bashNonInteractive}/bin/sh' '${preferredProfilePackages.bash}/bin/sh'

                # configure's WASI block puts -lwasi-emulated-signal into LIBS; wasix libc has
                # real signals and no such archive, so EVERY subsequent AC_LINK_IFELSE lib probe
                # failed (openssl/sqlite/readline -> "missing" _ssl/_hashlib/_sqlite3/readline).
                # The wrapper already links the emulated getpid/process-clocks libs itself.
                substituteInPlace configure.ac \
                  --replace-fail ' -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks' \
                                 ' -lwasi-emulated-getpid -lwasi-emulated-process-clocks'

                # configure hardcodes py_cv_module_mmap=n/a for WASI (and regenerates from
                # configure.ac, so patching configure doesn't stick); force the mmap module via
                # Setup.local. wasix has mmap and pandas imports it at load.
                echo "mmap mmapmodule.c" >> Modules/Setup.local

                # fcntl is n/a'd the same way ("WASI SDK does not support file locking"), but
                # wasix libc has real fcntl/ioctl; only the POSIX lock commands are missing
                # (no F_SETLK/F_GETLK, no flock/lockf). Give the module the Linux values so it
                # compiles: fd-flag fcntl/ioctl work, lock calls fail at runtime with EINVAL.
                # gevent.subprocess needs the module for F_GETFL/F_SETFL.
                echo "fcntl fcntlmodule.c" >> Modules/Setup.local
                substituteInPlace Modules/fcntlmodule.c \
                  --replace-fail '#include <sys/ioctl.h>            // ioctl()' \
                    '#include <sys/ioctl.h>            // ioctl()
        #ifdef __wasi__
        #  ifndef F_GETLK
        #    define F_GETLK 5
        #    define F_SETLK 6
        #    define F_SETLKW 7
        #  endif
        #  ifndef F_RDLCK
        #    define F_RDLCK 0
        #    define F_WRLCK 1
        #    define F_UNLCK 2
        #  endif
        #endif'

                # the #else wasi hits defines my_getpagesize but leaves my_getallocationgranularity
                # undefined → link error; alias it too (wasi has getpagesize).
                substituteInPlace Modules/mmapmodule.c \
                  --replace-fail "#define my_getpagesize getpagesize" \
                    "#define my_getpagesize getpagesize
        #define my_getallocationgranularity my_getpagesize"

                # More modules configure n/a's for WASI but whose libc backing wasix actually has:
                #   termios  - tc*/cf* all in libc.a
                #   pwd/grp  - getpw*/getgr* present; endpwent/endgrent stubbed in preBuild (no
                #              passwd/group db, so the iterators are empty at runtime)
                #   _curses/_curses_panel - ncurses + libpanel are inputs
                # Forced via Setup.local (configure regenerates from configure.ac, so a patch
                # wouldn't stick), the mmap/fcntl precedent above.
                {
                  echo "termios termios.c"
                  echo "pwd pwdmodule.c"
                  echo "grp grpmodule.c"
                  echo "_curses _cursesmodule.c -lncurses"
                  echo "_curses_panel _curses_panel.c -lpanel -lncurses"
                } >> Modules/Setup.local
      '';

      # Point the dangling python/python3 symlinks at the installed .wasm, and scrub the phantom
      # -lwasi-emulated-signal/-latomic (see postConfigure) from every place an extension build
      # reads link flags (pkgconfig, _sysconfigdata, config Makefile, python-config), else meson
      # feeds them to wasm-ld.
      postInstall = ''
        for n in python${pyVer} python3 python; do ln -sf python${pyVer}.wasm "$out/bin/$n"; done

        for f in \
          "$out"/lib/pkgconfig/python-*.pc \
          "$out"/lib/python${pyVer}/_sysconfigdata*.py \
          "$out"/lib/python${pyVer}/config-*/Makefile \
          "$out"/bin/python${pyVer}-config; do
          [ -e "$f" ] && sed -i 's/-lwasi-emulated-signal//g; s/-latomic//g' "$f"
        done

        # PEP 739 build-details.json (new in 3.14) is generated from the build
        # interpreter on cross builds, so abi.extension_suffix is absent and
        # suffixes.extensions carries the build-host suffix. maturin (the rust
        # wheels) requires abi.extension_suffix, so rewrite abi/suffixes from the
        # target's real EXT_SUFFIX.
        ${final.buildPackages.python3.interpreter} -c "import json,glob,sys; L=sys.argv[1]; g={}; exec(open(glob.glob(L+'/_sysconfigdata*.py')[0]).read(),g); e=g['build_time_vars']['EXT_SUFFIX']; p=L+'/build-details.json'; d=json.load(open(p)); d['abi']['extension_suffix']=e; d['abi'].setdefault('stable_abi_suffix','.abi3.so'); d['suffixes']['extensions']=[e,'.abi3.so','.so']; json.dump(d,open(p,'w'),indent=2)" "$out/lib/python${pyVer}"
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

      # ehpic only: the wasix sysroot ships dlfcn.h + dlopen/dlsym only in its PIC variants,
      # which ctypes and dynamic extension loading need. Other profiles are unsupported (not
      # broken); this also makes ehpic the preferred profile. autoSelfMount mounts the store
      # paths the wasm embeds (including PREFIX=$out, the stdlib).
      passthru = {
        wasix.supportedProfiles = ["ehpic"];
        wasmer = {
          name = "python";
          entrypoint = "python${pyVer}";
          autoSelfMount = true;
          # autoSelfMount only scans bin/*.wasm, so paths living in a .py or the sysconfig are
          # mounted explicitly: the wasix bash (baked into subprocess.py) and tzdata
          # (--with-tzpath bakes it into _sysconfigdata, not the .wasm; else zoneinfo raises
          # "No time zone found").
          selfMounts = [preferredProfilePackages.bash final.buildPackages.tzdata];
          # Bundle a CA set so stdlib ssl verifies out of the box (else ssl has no default
          # trust store and https raises SSLCertVerificationError). SSL_CERT_FILE is honored
          # by openssl's default SSLContext. Keyed by the sole command name (bin/*.wasm ->
          # python3.13.wasm; python/python3 are symlinks and don't become commands).
          fs."/etc/ssl" = "${final.cacert}/etc/ssl";
          commandEnv."python${pyVer}" = {
            SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
            SSL_CERT_DIR = "/etc/ssl/certs";
          };
        };
      };
    } (prev.python3.override {
      # Build-platform tzdata: the cross tzcode doesn't build (getresuid), and null broke the
      # BUILD python's zoneinfo (babel/hypothesis suites). zoneinfo is platform-independent;
      # the webc mounts it via selfMounts above.
      tzdata = final.buildPackages.tzdata;
      gdbm = null;
      # libuuid backs the _uuid module; nixpkgs sets it null off Linux. The
      # overlay util-linux ships libuuid-only (see packages/util-linux.nix).
      libuuid = final.util-linux;
      bashNonInteractive = final.buildPackages.bashNonInteractive;
      # `self = py` makes python3.pkgs.<pkg> build against THIS python, not the unfixed python313.
      self = py;
      packageOverrides = pythonPackageOverrides;
    });
in
  py
