# Off-EH profile only: bash needs fork() (-> asyncify) and setjmp/longjmp, which
# collide under Wasm-EH but coexist in off-EH. It declares supportedProfiles =
# ["off"] (so preferredPackages.bash resolves to the off build) and still
# evaluates in any profile — but BUILDING it under Wasm-EH fails loudly in
# preConfigure. readline auto-threads (final.readline, the off-profile build).
{
  final,
  prev,
  helpers,
  ...
}: let
  offProfile = (final.stdenv.hostPlatform.wasmExceptions or "yes") == "no";
in
  helpers.libTweaks {
    configureFlags = [
      "--without-bash-malloc" # bash's malloc assumes sbrk/brk; use libc's.
      "--disable-nls"
      "--disable-process-substitution" # needs mkfifo/mknod, absent on WASIX.
      "--disable-job-control" # no process groups; setpgid() EINVAL spam.
      "bash_cv_getenv_redef=no" # else getenv.o redefines putenv/setenv, clashes under wasm-ld.
      "bash_cv_func_sigsetjmp=missing" # off-EH <setjmp.h> gates sigsetjmp out.
      "ac_cv_func_siginterrupt=no" # libc has it but <signal.h> doesn't declare it.
    ];
    postPatch = ''
      # NO_MAIN_ENV_ARG drops main()'s `env`, but shell.c still uses it.
      substituteInPlace shell.c \
        --replace-fail '#if defined (__OPENNT) || defined (__MVS__)' \
                       '#if defined (__OPENNT) || defined (__MVS__) || defined (NO_MAIN_ENV_ARG)'
      substituteInPlace lib/sh/getcwd.c \
        --replace-fail '#if !defined (HAVE_GETCWD)' \
                       '#if !defined (HAVE_GETCWD) && !defined(__wasi__)'
      substituteInPlace lib/sh/winsize.c \
        --replace-fail '#if defined (TIOCGWINSZ) || defined (HAVE_TCGETWINSIZE)' \
                       '#if (defined (TIOCGWINSZ) || defined (HAVE_TCGETWINSIZE)) && !defined(__wasi__)'
    '';
    # passthru.wasix.* = our build-graph metadata (vs passthru.wasmer.* = webc
    # config); the support contract makes off the only (hence preferred) profile,
    # so preferredPackages.bash resolves to the off build.
    passthru.wasix.supportedProfiles = ["off"];
    # Eval everywhere (so the contract is readable without building), but refuse
    # to BUILD outside off-EH.
    preConfigure = final.lib.optionalString (!offProfile) ''
      echo 'bash must be built in the off-EH profile (wasmExceptions = "no")' >&2
      exit 1
    '';
    doInstallCheck = false;
    # readline is linked statically, so bash also needs its ncurses (termcap).
    buildInputs = [final.ncurses];
    env = {
      # gnu17: clang defaults to C23 where `bool` is a keyword bash redefines.
      # NO_MAIN_ENV_ARG: WASI clang only wraps a 2-arg main(); pick bash's.
      CFLAGS = "-std=gnu17 -g -O2 -DNO_MAIN_ENV_ARG";
      # readline+bash both define xmalloc/sh_get_env_value; wasm-ld rejects the
      # duplicates GNU ld would first-wins. Via NIX_LDFLAGS (straight to wasm-ld).
      NIX_LDFLAGS = "--allow-multiple-definition";
      bash_cv_termcap_lib = "libncurses";
      # asyncify bash.wasm at link: wasixcc auto-adds --asyncify for the off
      # profile, and bash also needs --fpcast-emu.
      WASIXCC_WASM_OPT_FLAGS = "--fpcast-emu";
    };
    # mkbuiltins et al. run on the build host: native cc, same gnu17 pin.
    preBuild = ''
      makeFlagsArray+=("CC_FOR_BUILD=${final.buildPackages.stdenv.cc}/bin/cc -std=gnu17")
    '';
    # Ship as *.wasm (already asyncified at link, above) + repoint bin/sh at the
    # renamed wasm. (Custom ordering — not the wasmRename helper — because sh must
    # be repointed after the rename.)
    postInstall = ''
      if [ -f "$out/bin/bash" ]; then
        mv "$out/bin/bash" "$out/bin/bash.wasm"
      fi
      if [ -L "$out/bin/sh" ]; then
        ln -sf bash.wasm "$out/bin/sh"
      fi
    '';
  }
  prev.bash
