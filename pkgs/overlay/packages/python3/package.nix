# CPython for wasix, following the wasix-org/cpython recipe. Shipped for 3.13 and 3.14
# as versions of python/python; `python3` aliases the current 3.14 derivation.
# ehpic only: dl/ctypes need the PIC sysroot.
{
  names = ["python3" "python313" "python314"];
  packages = {
    final,
    prev,
    preferredProfilePackages,
    helpers,
    toolchain,
    nix-update-script,
    ...
  }: let
    lib = prev.lib;
    current = prev.python314;

    mkWasixPython = base: let
      pyVer = base.pythonVersion;
      pythonCommand = name: {
        inherit name;
        module = "python";
        wasm = "python${pyVer}.wasm";
        output = "python${pyVer}.wasm";
        env = {
          SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
          SSL_CERT_DIR = "/etc/ssl/certs";
          # getpath can't resolve argv0 (no PATH in the guest), leaving sys.executable
          # empty, which breaks subprocess([sys.executable, ..]) and spawn.
          PYTHONEXECUTABLE = "${py}/bin/python${pyVer}.wasm";
        };
      };
      py =
        helpers.libTweaks {
          configureFlags = [
            "--enable-wasm-dynamic-linking"
            # configure hardcodes ipv6=no for WASI, whose libc has no AF_INET6.
            # WASIX has it, and without this a passive getaddrinfo still returns
            # AF_INET6 while socketmodule cannot parse it: "bind(): bad family".
            "--enable-ipv6"
            # configure disables pymalloc for WASI along with Emscripten. It works
            # here, and allocation-heavy code runs ~15% faster with it.
            "--with-pymalloc"
            # nixpkgs presets ac_cv_x87_double_rounding=yes for every cross build, an
            # x86-only assumption; at "yes" pycore_pymath.h drops Python/dtoa.c and
            # repr(1.1) prints 1.1000000000000001. A configure argument beats nixpkgs' env.
            "ac_cv_x87_double_rounding=no"
          ];

          # Autoconf cache vars; the build re-runs autoreconf, so fresh probes must see these.
          env = {
            # Pull libc++/libc++abi into the dynamic main and export them, so the C++
            # extension .so's dlopened into it share one copy (cross-module RTTI and EH).
            WASIXCC_INCLUDE_CPP_SYMBOLS = "yes";
            # clang 21 defaults to -std=gnu23, breaking configure's "CC name" conftest.
            ac_cv_cc_name = "clang";
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
            # In the sysroot, but the cross probe defaults off.
            ac_cv_header_sys_mman_h = "yes";
            ac_cv_header_sys_stat_h = "yes";
            # In libc.a, but the -lm probe can't see them (libm.a is an empty stub).
            ac_cv_func_acosh = "yes";
            ac_cv_func_asinh = "yes";
            ac_cv_func_atanh = "yes";
            ac_cv_func_erf = "yes";
            ac_cv_func_erfc = "yes";
            ac_cv_func_expm1 = "yes";
            ac_cv_func_log1p = "yes";
            ac_cv_func_log2 = "yes";
            ac_cv_func_timegm = "yes";
            ac_cv_func_strftime = "yes"; # probe-missed
            # From -lwasi-emulated-process-clocks; without HAVE_CLOCK* the callers link against nothing.
            ac_cv_func_clock = "yes";
            ac_cv_func_clock_gettime = "yes";
            ac_cv_func_dup2 = "yes"; # in PIC libc.a but AC_REPLACE_FUNCS misses it → duplicate dup2
            ac_cv_func_mmap = "yes"; # emulated-mman, always linked; cross probe defaults to no
            # Without lstat, os.lstat→realpath raises NotImplementedError and ctypes breaks.
            ac_cv_func_lstat = "yes";
            ac_cv_func_fstatat = "yes";
            ac_cv_func_readlink = "yes";
            ac_cv_func_readlinkat = "yes";
            # posix_spawn and the subprocess pipeline: in libc, but probe-missed or
            # WASI-disabled upstream. HAVE_EXECV gates posix_spawn's arglist parsing.
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
            ac_cv_func_getpid = "yes"; # emulated-getpid
            ac_cv_func_uname = "yes";
            ac_cv_func_gethostname = "yes";
            # HAVE_SIGSET_T (posix_spawn's restore_signals) gates on these; all in libc, undetected.
            ac_cv_func_pthread_sigmask = "yes";
            ac_cv_func_sigwait = "yes";
            ac_cv_func_sigtimedwait = "yes";
            ac_cv_func_sigwaitinfo = "yes";
            # wasix has real pthreads; configure defaults WASI to clashing stubs.
            ac_cv_pthread = "yes";
            # readline.pc requires a termcap with no termcap.pc, so pkg-config fails and the
            # fallback misses ncurses' symbols. Setting both result vars skips PKG_CHECK_MODULES.
            LIBREADLINE_CFLAGS = "-I${lib.getDev final.readline}/include";
            LIBREADLINE_LIBS = "-lreadline -lncurses";
            # clang 16+ makes implicit-decl/int-conversion hard errors → autoconf conftests fail.
            NIX_CFLAGS_COMPILE = "-Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -Wno-deprecated-non-prototype";
          };

          patches = [
            # find_library's posix branch shells out to ldconfig/gcc, returning None on wasm.
            ./patches/ctypes-find-library-wasi.patch
            ./patches/enable-wasm-dynamic-linking-wasi.patch
            # wasi has no fork, so subprocess goes through posix_spawn.
            ./patches/subprocess-posix-spawn-wasi.patch
            # Same for multiprocessing; 3.14 restructured context.py and util.py, hence two.
            (
              if lib.versionAtLeast pyVer "3.14"
              then ./patches/multiprocessing-posix-spawn-wasi-314.patch
              else ./patches/multiprocessing-posix-spawn-wasi.patch
            )
            # wasm call_indirect traps on the arity-mismatched METH_NOARGS casts common in
            # third-party extensions; the trampoline dispatches via wasix call_dynamic.
            ./patches/wasix-call-trampoline.patch
          ];

          # wasix-libc declares but doesn't implement some libc fns → cpython compiles the
          # callers (os.openpty, the forced pwd/grp modules) → undefined at link.
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

          # The libatomic probe (gh-109054) puts -latomic into LIBS; wasix has no such
          # archive. The installed sysconfig carries it too, scrubbed in postInstall.
          postConfigure = ''
            sed -i 's/ -latomic//g' Makefile
          '';

          # Fixups configure gets wrong for WASI. Its WASI LIBS block names
          # -lwasi-emulated-signal, which wasix has no archive for, so every later
          # AC_LINK_IFELSE lib probe fails to link. MACHDEP=wasix sets sys.platform while
          # ac_sys_system stays WASI. Setup.local forces the modules configure marks n/a.
          postPatch = ''
                    substituteInPlace Lib/subprocess.py \
                      --replace-fail '${final.buildPackages.bashNonInteractive}/bin/sh' '${preferredProfilePackages.bash}/bin/sh'

                    substituteInPlace configure.ac \
                      --replace-fail ' -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks' \
                                     ' -lwasi-emulated-getpid -lwasi-emulated-process-clocks'

                    substituteInPlace configure.ac \
                      --replace-fail 'aix*) MACHDEP="aix";;' 'aix*) MACHDEP="aix";;
            	wasi) MACHDEP="wasix";;'

                    substituteInPlace configure.ac \
                      --replace-fail "AC_SUBST([PLATFORM_HEADERS])" \
                    "AS_CASE([\$ac_sys_system], [WASI], [
              AS_VAR_APPEND([PLATFORM_OBJS], [' Python/wasix_trampoline.o'])
              AS_VAR_APPEND([PLATFORM_HEADERS], [' \$(srcdir)/Include/internal/pycore_emscripten_trampoline.h'])
            ])
            AC_SUBST([PLATFORM_HEADERS])"

                    echo "mmap mmapmodule.c" >> Modules/Setup.local

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

                    substituteInPlace Modules/mmapmodule.c \
                      --replace-fail "#define my_getpagesize getpagesize" \
                        "#define my_getpagesize getpagesize
            #define my_getallocationgranularity my_getpagesize"

                    {
                      echo "termios termios.c"
                      echo "pwd pwdmodule.c"
                      echo "grp grpmodule.c"
                      echo "_curses _cursesmodule.c -lncurses"
                      echo "_curses_panel _curses_panel.c -lpanel -lncurses"
                      echo "_multiprocessing _multiprocessing/multiprocessing.c _multiprocessing/semaphore.c"
                      echo "_posixshmem _multiprocessing/posixshmem.c"
                    } >> Modules/Setup.local

                    substituteInPlace Lib/site.py Lib/sysconfig/__init__.py \
                      --replace-fail '"vxworks", "wasi", "watchos"' '"vxworks", "wasi", "wasix", "watchos"'
          '';

          # Scrub -latomic wherever an extension build reads link flags, else meson feeds it to
          # wasm-ld. build-details.json comes from the build interpreter, so it lacks EXT_SUFFIX.
          postInstall = ''
            for n in python${pyVer} python3 python; do ln -sf python${pyVer}.wasm "$out/bin/$n"; done

            # `python -m pip` works under wasix, but ensurepip installs it by running
            # the target interpreter, which a cross build cannot do. The wheel it
            # bundles is pure python, so unpack that instead.
            whl=$(echo "$out"/lib/python${pyVer}/ensurepip/_bundled/pip-*.whl)
            [ -f "$whl" ] || { echo "no bundled pip wheel in $out" >&2; exit 1; }
            ${final.buildPackages.python3}/bin/python3 -m zipfile -e "$whl" \
              "$out/lib/python${pyVer}/site-packages"

            for f in \
              "$out"/lib/pkgconfig/python-*.pc \
              "$out"/lib/python${pyVer}/_sysconfigdata*.py \
              "$out"/lib/python${pyVer}/config-*/Makefile \
              "$out"/bin/python${pyVer}-config; do
              [ -e "$f" ] && sed -i 's/-latomic//g' "$f"
            done

            if [ -e "$out/lib/python${pyVer}/build-details.json" ]; then
              ${final.buildPackages.python3.interpreter} -c "import json,glob,sys; L=sys.argv[1]; g={}; exec(open(glob.glob(L+'/_sysconfigdata*.py')[0]).read(),g); e=g['build_time_vars']['EXT_SUFFIX']; p=L+'/build-details.json'; d=json.load(open(p)); d['abi']['extension_suffix']=e; d['abi'].setdefault('stable_abi_suffix','.abi3.so'); d['suffixes']['extensions']=[e,'.abi3.so','.so']; json.dump(d,open(p,'w'),indent=2)" "$out/lib/python${pyVer}"
            fi

          '';

          # nixpkgs' sysconfigdata hook hardcodes _PYTHON_HOST_PLATFORM from the nix platform;
          # keeping it in sync with MACHDEP=wasix is what gives wheels the wasix_wasm32 tag.
          postFixup = ''
            substituteInPlace "$out/nix-support/setup-hook" \
              --replace-fail "_PYTHON_HOST_PLATFORM='wasip1-wasm32'" "_PYTHON_HOST_PLATFORM='wasix-wasm32'"
          '';

          dontCheckForBrokenSymlinks = true;

          # dev-tool shebangs point at the build-platform bash; it never runs under wasmer.
          disallowedReferences = drf:
            builtins.filter (r: r != final.buildPackages.bashNonInteractive)
            (
              if drf == null
              then []
              else drf
            );

          passthru = {
            wasix.shipped = true;
            # dlfcn.h and dlopen/dlsym, needed by ctypes, ship only in the PIC sysroots.
            wasix.supportedProfiles = ["ehpic"];
            # PYO3_CROSS_LIB_DIR and setuptools-rust's pyLibDir, so a 3.13 wheel targets 3.13.
            crossLibDir = "${py}/lib/${py.libPrefix}";
            # cmake Python_INCLUDE_DIR for C-extension wheels; find_package(Python) otherwise
            # picks the build interpreter's 64-bit headers and pyport.h fatals on wasm32.
            crossIncludeDir = "${py}/include/${py.libPrefix}";
            wasmer = {
              owner = "python";
              name = "python";
              history = pyVer != current.pythonVersion;
              aliases =
                if pyVer == current.pythonVersion
                then ["python3" "python314"]
                else ["python313"];
              entrypoint = "python${pyVer}";
              # Consumers address the atom as <package>:python; each command
              # shares it while Wasmer exposes the usual names under /bin.
              commands = map pythonCommand ["python${pyVer}" "python3" "python"];
              autoSelfMount = true;
              # autoSelfMount only scans bin/*.wasm, but bash is baked into subprocess.py and
              # tzdata into _sysconfigdata (else zoneinfo raises "No time zone found").
              selfMounts = [preferredProfilePackages.bash final.buildPackages.tzdata];
              # Without a bundled CA set, https raises SSLCertVerificationError.
              fs."/etc/ssl" = "${final.cacert}/etc/ssl";
            };
          };
        } (base.override {
          # The cross tzcode doesn't build (getresuid), and null breaks the build python's
          # zoneinfo; the platform-independent data is mounted into the webc via selfMounts.
          tzdata = final.buildPackages.tzdata;
          gdbm = null;
          # nixpkgs sets libuuid null off Linux; the overlay util-linux ships libuuid only.
          libuuid = final.util-linux;
          bashNonInteractive = final.buildPackages.bashNonInteractive;
          # python3.pkgs.<pkg> then builds against THIS python, not the unfixed python313.
          self = py;
          # Imported per python so each interpreter's extension wheels cross-build against
          # the python they target, not the default. `.override` also splices packageOverrides
          # onto the native pythonForBuild, which the isWasixHost gate below keeps vanilla;
          # setuptools-rust is exempt as a build-host tool that compiles rust for wasix.
          packageOverrides = pyfinal: pyprev: let
            # Includes the registry-history attrs (numpy_2_1_3, ...) the loader mints.
            wasixOverrides =
              (import ../../python-packages {
                callArgs = {
                  inherit final prev preferredProfilePackages helpers lib toolchain nix-update-script;
                  wasixPython = py;
                };
              })
              pyfinal
              pyprev
              // {
                # PYO3_CROSS_LIB_DIR for every rust/pyo3 wheel, set on the python's own builder
                # because it is interpreter-specific. extendMkDerivation keeps the functor set
                # intact, but forwards neither `override` nor the wrapper, so re-attach both.
                buildPythonPackage = let
                  withPyo3 = bpp:
                    lib.extendMkDerivation {
                      constructDrv = bpp;
                      extendDrvArgs = _finalAttrs: prevArgs: {
                        env = {PYO3_CROSS_LIB_DIR = "${py}/lib/${py.libPrefix}";} // (prevArgs.env or {});
                      };
                    };
                in
                  withPyo3 pyprev.buildPythonPackage
                  // {override = args: withPyo3 (pyprev.buildPythonPackage.override args);};
              };
          in
            if pyprev.python.stdenv.hostPlatform.isWasix or false
            then wasixOverrides
            else {inherit (wasixOverrides) setuptools-rust;};
        });
    in
      py;
  in rec {
    python313 = mkWasixPython prev.python313;
    python314 = mkWasixPython current;
    python3 = python314;
  };
}
