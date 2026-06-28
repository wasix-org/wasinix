# python3 (CPython 3.13.13) for wasix. Path A: nixpkgs upstream cpython (which has plain
# wasm32-wasi support) built under the wasix stdenv, with the overlay wasix libs auto-threading
# in (openssl, ncurses, sqlite, readline, zlib, bzip2, expat, xz, mpdecimal, libffi). Reference:
# build-scripts' wasix-org/cpython recipe (see memory wasix-python-packaging).
#
# Dropped deps that don't cross-build to wasm (none are in build-scripts' core set):
# - tzdata: nixpkgs compiles tzcode/zic with the *target* cc → wasm unix-isms. zoneinfo finds
#   tz data at runtime (no baked --with-tzpath).
# - gdbm: gdbmshell.c calls fork() → undeclared on wasm. Drops the dbm.gnu module.
#
# bashNonInteractive is the build-platform bash (the wasix cross bash doesn't build — jobs.c fork);
# it's only used for patchShebangs on dev tools, and subprocess(shell=True)'s baked /bin/sh is
# reverted to a literal (postPatch). TODO: bake a wasix bash + enable posix_spawn for subprocess.
{
  final,
  prev,
  preferredPackages,
  helpers,
  ...
}: let
  lib = prev.lib;
  hp = final.stdenv.hostPlatform;

  # Build only on legacy-EH + PIC (the "ehpic" variant). PIC is required for dl: the wasix sysroot
  # ships dlfcn.h + dlopen/dlsym only in its PIC variants (Makefile-eh gates the musl ldso on PIC),
  # and ctypes + dynamic extension loading need them. Other profiles are genuinely unsupported (not
  # broken) — marked via meta.badPlatforms below.
  isSupported = helpers.variantOf hp == "ehpic";

  # wasix overrides for the Python package set (the python-package analogue of overlay/packages/).
  # Folded into cpython's packageOverrides below, so every python3.pkgs.<pkg> can carry
  # wasix-specific build fixes/patches. See overlay/python-packages/.
  pythonPackageOverrides = import ../../python-packages {
    inherit lib;
    callArgs = {inherit final prev preferredPackages helpers lib;};
  };

  py = helpers.libTweaks {
    # Enable dynamic linking → import of .so C-extension modules (wheels). Allowed for WASI by
    # patches/enable-wasm-dynamic-linking-wasi.patch (upstream hard-errors on it); the flag then
    # cascades ac_cv_func_dlopen=yes → DYNLOADFILE=dynload_shlib.o → HAVE_DYNAMIC_LOADING. Our
    # ehpic main module is already built -pie/--experimental-pic, so no extra link flags needed.
    configureFlags = ["--enable-wasm-dynamic-linking"];

    # Autoconf cache vars: feed configure what the wasix-org/cpython fork's config.site / configure
    # patches would, declaratively (the build re-runs autoreconf+configure, so a fresh probe must
    # see these in the env). From build-scripts' config.site-wasm32-wasix + wasix-libc-reality fixes.
    env = {
      # clang 21 defaults to -std=gnu23, which breaks configure's "CC compiler name" conftest.
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
      ac_cv_func_memfd_create = "no"; # declared but its probe genuinely fails
      # Math funcs that ARE in libc.a but the -lm probe can't see (libm.a is an empty wasi-libc
      # stub); timegm is a GNU extension. Without these, cpython compiles static fallbacks that
      # clash with the real header declarations.
      ac_cv_func_acosh = "yes";
      ac_cv_func_asinh = "yes";
      ac_cv_func_atanh = "yes";
      ac_cv_func_erf = "yes";
      ac_cv_func_erfc = "yes";
      ac_cv_func_expm1 = "yes";
      ac_cv_func_log1p = "yes";
      ac_cv_func_log2 = "yes";
      ac_cv_func_timegm = "yes";
      # clock/clock_gettime come from -lwasi-emulated-process-clocks (still linked). Without
      # HAVE_CLOCK*, pytime.c/timemodule.c guard out the definers while their users stay → undef.
      ac_cv_func_clock = "yes";
      ac_cv_func_clock_gettime = "yes";
      # The PIC libc.a defines dup2, but configure's AC_REPLACE_FUNCS probe misses it at PIC →
      # cpython compiles Python/dup2.c → "duplicate symbol: dup2". Force present.
      ac_cv_func_dup2 = "yes";
      # cpython's plain-WASI support assumes no symlink stat, but WASIX implements lstat/fstatat/
      # readlink. Without these os.lstat → realpath → NotImplementedError → sysconfig (hence
      # `import ctypes`) breaks. All four are in the (PIC) libc + declared in the headers.
      ac_cv_func_lstat = "yes";
      ac_cv_func_fstatat = "yes";
      ac_cv_func_readlink = "yes";
      ac_cv_func_readlinkat = "yes";
      # wasix has real pthreads (the stdenv compiles -pthread -matomics -mbulk-memory + the sysroot
      # has them); configure defaults WASI to thread *stubs* that clash with the real headers. Force
      # real pthreads. (Do NOT use --enable-wasm-pthreads — it switches to the wasm32-wasi-threads
      # target + memory flags that fight the wasix target/stdenv.)
      ac_cv_pthread = "yes";
      # clang 16+ makes implicit-function-declaration / int-conversion hard errors, breaking
      # autoconf's legacy conftests (every AC_CHECK_FUNC probe fails to compile). Relax to warn.
      NIX_CFLAGS_COMPILE = "-Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -Wno-deprecated-non-prototype";
    };

    patches = [
      # ctypes.util.find_library for wasi/wasix: upstream's generic-posix branch shells out to
      # ldconfig/gcc (no-ops on wasm → None); add a branch that resolves builtins to the main
      # module and searches the standard dirs for a wasm dylib (a `dylink.0` module).
      ./patches/ctypes-find-library-wasi.patch
      # Allow --enable-wasm-dynamic-linking on WASI (upstream errors "not implemented yet").
      ./patches/enable-wasm-dynamic-linking-wasi.patch
    ];

    # wasix-libc DECLARES but doesn't IMPLEMENT the pty fns (grantpt/unlockpt/ptsname/openpty), so
    # configure sets HAVE_* and cpython compiles os.grantpt/os.openpty → undefined at link.
    # Disabling python-side is whack-a-mole (the build re-runs autoreconf+configure regenerating
    # pyconfig.h, and Argument Clinic splits impl from the generated wrapper). Provide ENOSYS stubs
    # and link them — survives the re-configure. TODO: implement in wasix-libc upstream.
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

    # configure's WASI block links -lwasi-emulated-signal (wasix has real signals in libc — no such
    # lib) and the atomic check adds -latomic (wasm atomics are intrinsic via -matomics). Both break
    # the link; drop them from the generated Makefile.
    postConfigure = ''
      sed -i 's/ -lwasi-emulated-signal//g; s/ -latomic//g' Makefile
    '';

    # cpython bakes ${bashNonInteractive}/bin/sh into subprocess(shell=True)'s shell — the
    # build-platform (x86_64) bash, which would bloat the wasm closure. Revert to a literal /bin/sh
    # for now (subprocess is still cpython-disabled on wasi until posix_spawn is wired up — a TODO).
    # A substituteInPlace, not a .patch, because the bash store path is dynamic.
    postPatch = ''
      substituteInPlace Lib/subprocess.py \
        --replace-fail '${final.buildPackages.bashNonInteractive}/bin/sh' '/bin/sh'
    '';

    # The interpreter installs as python3.13.wasm, so the python3.13/python3/python symlinks dangle
    # (they expect a non-.wasm binary). Point them all at the .wasm.
    postInstall = ''
      for n in python3.13 python3 python; do ln -sf python3.13.wasm "$out/bin/$n"; done
    '';

    dontCheckForBrokenSymlinks = true;

    # Keep cpython's reference check, but allow the build-platform bash: its dev tools
    # (python3.13-config, the config-3.13 Makefile) carry a shell shebang patchShebangs points at
    # the build bash — harmless (they never run under wasmer). The build-host-python guard stays on.
    disallowedReferences = drf:
      builtins.filter (r: r != final.buildPackages.bashNonInteractive)
      (if drf == null then [] else drf);

    # Ship at the ehpic profile, and configure the webc: autoSelfMount mounts the store paths the
    # wasm embeds (incl. python's baked PREFIX=$out), so the stdlib at $out/lib/python3.13 is found
    # at runtime — no manual --volume. The command is python3.13 (the bin/*.wasm).
    passthru = {
      wasix.preferredProfile = "ehpic";
      wasmer = {
        name = "python";
        entrypoint = "python3.13";
        autoSelfMount = true;
      };
    };

    # Genuinely unsupported (not broken) off legacy-EH+PIC: ctypes/dl need PIC, which only the *pic
    # sysroot variants ship. Mark the profile unsupported rather than broken (deep-merged: appends
    # to meta.badPlatforms).
    meta.badPlatforms = lib.optionals (!isSupported) [hp.system];
  } (prev.python3.override {
    tzdata = null;
    gdbm = null;
    bashNonInteractive = final.buildPackages.bashNonInteractive;
    # Rethread the package set onto OUR python. Without `self`, python3.pkgs.<pkg> builds against
    # the original unfixed python313 (tzdata, no dynamic linking, …). `self = py` makes .pkgs use
    # this override (recursive; used lazily for .pkgs only, so it doesn't rebuild the interpreter).
    self = py;
    packageOverrides = pythonPackageOverrides;
  });
in
  py
