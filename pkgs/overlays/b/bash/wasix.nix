# Off-EH profile only: bash needs fork() (via asyncify) and setjmp/longjmp,
# which collide under Wasm-EH but coexist in off-EH. It evaluates in any
# profile but refuses to build outside off-EH (preConfigure below). readline
# auto-threads in as the off-profile build.
{
  exposeWasixExtendedPackage,
  packages,
}: let
  offProfile = (packages.sameProfile.stdenv.hostPlatform.wasmExceptions or "yes") == "no";
in
  exposeWasixExtendedPackage {
    configureFlags = [
      "--without-bash-malloc" # bash's malloc assumes sbrk/brk; use libc's.
      "--disable-nls"
      # Process substitution over /dev/fd, which the runtime resolves to the
      # caller's fd. mkfifo is ENOSYS, so deny the named-pipe path outright
      # rather than let bash fall back to it.
      "bash_cv_dev_fd=standard"
      "bash_cv_sys_named_pipes=missing"
      "--disable-job-control" # no process groups; setpgid() EINVAL spam.
      "bash_cv_getenv_redef=no" # else getenv.o redefines putenv/setenv, clashes under wasm-ld.
      # libc's sigsetjmp ignores the signal mask, so take bash's own save/restore.
      "bash_cv_func_sigsetjmp=missing"
    ];
    postPatch = ''
      # NO_MAIN_ENV_ARG drops main()'s `env`, but shell.c still uses it.
      substituteInPlace shell.c \
        --replace-fail '#if defined (__OPENNT) || defined (__MVS__)' \
                       '#if defined (__OPENNT) || defined (__MVS__) || defined (NO_MAIN_ENV_ARG)'
      substituteInPlace lib/sh/getcwd.c \
        --replace-fail '#if !defined (HAVE_GETCWD)' \
                       '#if !defined (HAVE_GETCWD) && !defined(__wasi__)'
      # Without mkfifo, bash builds its own out of mknod, which WASIX lacks
      # too. Process substitution only reaches that path when HAVE_DEV_FD is
      # unset, and it is set here.
      substituteInPlace lib/sh/oslib.c \
        --replace-fail '#if !defined (HAVE_MKFIFO) && defined (PROCESS_SUBSTITUTION)' \
                       '#if !defined (HAVE_MKFIFO) && defined (PROCESS_SUBSTITUTION) && !defined(__wasi__)'
    '';
    passthru = {
      wasix.supportedProfiles = ["off"];
      wasinix.shipped = true;
      wasmer = {
        # Both commands share the one module, so dependents get /bin/sh as well
        # as /bin/bash and the webc still carries a single wasm. A second command
        # means wasmer no longer infers one, hence the explicit entrypoint.
        entrypoint = "bash";
        # A shell with nothing to run is not a shell: wasmer mounts each
        # dependency command under /bin, which is where DEFAULT_PATH_VALUE
        # points.
        dependencies = [packages.wasix.preferred.coreutils];
        commands = [
          {name = "bash";}
          {
            name = "sh";
            module = "bash";
            wasm = "bash.wasm";
            output = "bash.wasm";
          }
        ];
      };
    };
    preConfigure = packages.sameProfile.lib.optionalString (!offProfile) ''
      echo 'bash must be built in the off-EH profile (wasmExceptions = "no")' >&2
      exit 1
    '';
    doInstallCheck = false;
    # readline is linked statically, so bash also needs its ncurses (termcap).
    buildInputs = [packages.sameProfile.ncurses];
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
      # nixpkgs bakes /no-such-path as the fallback PATH and command -p path.
      # wasmer mounts a webc's dependency commands at /bin and /usr/bin, so an
      # unset PATH must search there. Clang takes the last -D, hence the -U.
      NIX_CFLAGS_COMPILE = old:
        old
        + ''
          -UDEFAULT_PATH_VALUE -DDEFAULT_PATH_VALUE="/bin:/usr/bin"
          -USTANDARD_UTILS_PATH -DSTANDARD_UTILS_PATH="/bin:/usr/bin"
        '';
    };
    # mkbuiltins et al. run on the build host: native cc, same gnu17 pin.
    preBuild = ''
      makeFlagsArray+=("CC_FOR_BUILD=${packages.sameProfile.lib.getExe' packages.sameProfile.buildPackages.stdenv.cc "cc"} -std=gnu17")
    '';
    # Ship as *.wasm (already asyncified at link) and repoint bin/sh at the
    # renamed wasm. Done by hand, not via the wasmRename helper, because sh
    # must be repointed after the rename.
    postInstall = ''
      if [ -f "$out/bin/bash" ]; then
        mv "$out/bin/bash" "$out/bin/bash.wasm"
      fi
      if [ -L "$out/bin/sh" ]; then
        ln -sf bash.wasm "$out/bin/sh"
      fi
    '';
  }
