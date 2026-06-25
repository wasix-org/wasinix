{
  lib,
  toolchain,
  bash,
  readline,
  ncurses,
  ...
}:
# Off-EH profile only: bash needs fork() (-> asyncify) and setjmp/longjmp, which
# collide under Wasm-EH but coexist in off-EH, where libc does longjmp via
# asyncify.
assert lib.assertMsg ((toolchain.wasmExceptions or "yes") == "no")
"bash must be built in the off-EH profile (wasmExceptions = \"no\")";
# .override so propagatedBuildInputs picks up our readline too, not just buildInputs.
  (bash.override {
    inherit readline;
    stdenv = toolchain.stdenv;
  }).overrideAttrs (old: {
    # readline is linked statically, so bash also needs its ncurses (termcap).
    buildInputs = (old.buildInputs or []) ++ [ncurses];
    env =
      (old.env or {})
      // {
        # gnu17: clang defaults to C23, where `bool` is a keyword bash redefines.
        # NO_MAIN_ENV_ARG: WASI clang only wraps a 2-arg main(); pick bash's.
        CFLAGS = "-std=gnu17 -g -O2 -DNO_MAIN_ENV_ARG";
        # readline/ncurses include+lib paths arrive via buildInputs propagation
        # (the cc-wrapper stdenv). readline and bash both define xmalloc/
        # sh_get_env_value; wasm-ld rejects the duplicates GNU ld would take
        # first-wins, so allow them — via NIX_LDFLAGS so the cc-wrapper passes it
        # straight to wasm-ld (hence no -Wl, prefix).
        NIX_LDFLAGS = "--allow-multiple-definition";
        bash_cv_termcap_lib = "libncurses";
      };
    # mkbuiltins et al. run on the build host: native cc, same gnu17 pin. Set via
    # makeFlagsArray (not makeFlags) because the value contains a space.
    preBuild =
      (old.preBuild or "")
      + ''
        makeFlagsArray+=("CC_FOR_BUILD=${toolchain.buildCc} -std=gnu17")
      '';
    configureFlags =
      (old.configureFlags or [])
      ++ [
        "--host=${toolchain.host}"
        # bash's malloc assumes sbrk/brk; use libc's.
        "--without-bash-malloc"
        "--disable-nls"
        # Process substitution needs mkfifo/mknod, absent on WASIX.
        "--disable-process-substitution"
        # setpgid() returns EINVAL (no process groups), so an interactive shell
        # spams "child setpgid: Invalid argument". fg/bg/^Z can't work anyway.
        "--disable-job-control"
        # nixpkgs pins this =yes, making getenv.o redefine putenv/setenv and clash
        # with libc under wasm-ld. Appended so it wins.
        "bash_cv_getenv_redef=no"
        # off-EH <setjmp.h> feature-gates sigsetjmp out; use plain setjmp.
        "bash_cv_func_sigsetjmp=missing"
        # libc has siginterrupt() but <signal.h> doesn't declare it; say it's
        # absent so bash builds its own instead of calling the undeclared symbol.
        "ac_cv_func_siginterrupt=no"
      ];
    hardeningDisable = ["all"];
    doCheck = false;
    doInstallCheck = false;
    postPatch =
      (old.postPatch or "")
      + ''
        # NO_MAIN_ENV_ARG drops main()'s `env`, but shell.c still uses it; declare
        # `env = environ` for our case like the existing platform guards do.
        substituteInPlace shell.c \
          --replace-fail '#if defined (__OPENNT) || defined (__MVS__)' \
                         '#if defined (__OPENNT) || defined (__MVS__) || defined (NO_MAIN_ENV_ARG)'

        # WASI lacks getcwd-fallback / terminal-size paths these branches assume.
        substituteInPlace lib/sh/getcwd.c \
          --replace-fail '#if !defined (HAVE_GETCWD)' \
                         '#if !defined (HAVE_GETCWD) && !defined(__wasi__)'
        substituteInPlace lib/sh/winsize.c \
          --replace-fail '#if defined (TIOCGWINSZ) || defined (HAVE_TCGETWINSIZE)' \
                         '#if (defined (TIOCGWINSZ) || defined (HAVE_TCGETWINSIZE)) && !defined(__wasi__)'
      '';
    postInstall =
      (old.postInstall or "")
      + ''
        # Ship as *.wasm (allWasm collects those); asyncify so fork()/longjmp can
        # suspend/resume under wasmer.
        if [ -f "$out/bin/bash" ]; then
          mv "$out/bin/bash" "$out/bin/bash.wasm"
          ${toolchain.binaryen}/bin/wasm-opt --asyncify --fpcast-emu -O2 \
            "$out/bin/bash.wasm" -o "$out/bin/bash.wasm"
        fi
        # Repoint bin/sh at the renamed wasm so it isn't a dangling symlink.
        if [ -L "$out/bin/sh" ]; then
          ln -sf bash.wasm "$out/bin/sh"
        fi
      '';
  })
