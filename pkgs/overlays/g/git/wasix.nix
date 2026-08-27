# Built in the default profile; execs the off-profile bash at runtime via
# SHELL_PATH=/bin/bash, mounted from the bash webc dependency (see the wasmer
# block) rather than bundled. gnugrep/gnused/gawk/coreutils are our wasix
# builds, since git bakes their paths into the shell subcommands.
{
  exposeWasixPackage,
  package,
  packages,
  dropInputsByName,
}:
exposeWasixPackage (
  let
    inherit (packages.sameProfile) lib;
    bash = packages.wasix.preferred.bash;
    nano = packages.wasix.preferred.nano;
    coreutils = packages.wasix.preferred.coreutils;
    gawk = packages.wasix.preferred.gawk;
  in
    (package.override {
      # gettext lands in nativeBuildInputs too, so the bare argument splices to
      # the build platform; git-sh-i18n needs the path it bakes to be the wasix
      # one. gnugrep/gnused need no such push: they are ours under those names.
      inherit (packages.sameProfile) gettext;
      inherit bash gawk coreutils;
      # `git p4` is the only consumer (exec'd, not linked) and
      # it needs a Perforce client which we don't have yet,
      # so there's no reason to pull in python yet.
      pythonSupport = false;
      # makeWrapper only wraps the Perl subcommands git omits.
      makeWrapper = null;
      nlsSupport = false;
      doInstallCheck = false;
      withpcre2 = true;
    })
  .overrideAttrs (old: {
      # SHELL_PATH is the literal /bin/bash and the webc mounts it, so nothing
      # links bash; propagating it puts an off-profile closure in the environment
      # of everything that depends on git.
      propagatedBuildInputs = dropInputsByName ["bash-interactive"] (old.propagatedBuildInputs or []);
      passthru =
        (old.passthru or {})
        // {
          inherit bash;
          wasinix.shipped = true;
          wasmer = {
            # certs for HTTPS clones, mounted where git/openssl look for them.
            fs."/etc/ssl" = "${packages.sameProfile.cacert}/etc/ssl";
            commandEnv.git = {
              SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
              # nano is a dependency command wasmer mounts under /bin. Without an
              # editor `git commit` and `git rebase -i` have nothing to open.
              # No pager: git's pager child hangs, see WASIX-TODO.md.
              GIT_EDITOR = "/bin/nano";
            };
            # git execs SHELL_PATH=/bin/bash (set below); wasmer's use_package
            # mounts this dependency's `bash` command there at load, so bash is
            # not bundled into git's webc.
            # The rest populate /bin for the shell git hands user-supplied code
            # to (hooks, aliases, filter-branch filters), which searches PATH.
            dependencies = [
              bash
              nano
              coreutils
              gawk
              packages.wasix.preferred.gnugrep
              packages.wasix.preferred.gnused
            ];
            # git execs its libexec helpers at absolute /nix/store paths; mount
            # whatever git.wasm embeds (bash is no longer embedded).
            autoSelfMount = true;
            # The shell subcommands exec grep, sed and the coreutils programs by
            # store path, which the wasm scan behind autoSelfMount cannot see.
            selfMounts = [packages.sameProfile.gnugrep packages.sameProfile.gnused coreutils gawk];
          };
        };
      makeFlags =
        old.makeFlags
        ++ [
          # nixpkgs cross sets these to flag missing symbols on plain WASI; WASIX
          # libc provides them, so clear to re-enable the native path.
          "NO_INET_NTOP="
          "NO_INET_PTON="
          "NO_TCLTK=YesPlease"
          # WASIX unlink() no-ops on .git/objects/aa/ files; use rename() instead.
          "OBJECT_CREATION_USES_RENAMES=YesPlease"
          # sysinfo() is in WASIX headers but absent from libc.a.
          "HAVE_SYSINFO="
          # configure can't run wasm test binaries; force-enable curl + OpenSSL.
          # curl's link flags come from curl-config in preConfigure so they track
          # curl's deps (brotli/zstd/...); OpenSSL is just -lssl -lcrypto.
          "NO_CURL="
          "NO_OPENSSL="
          "OPENSSL_LINK=-lssl -lcrypto"
          # Skip test-tool/unit-tests: `all::` builds them, a cross build can never
          # run them, and unit-tests contains setjmp (wasm-EH instructions under
          # the EH profiles) that the link-time asyncify pass can't process.
          "TEST_PROGRAMS="
          "CLAR_TEST_PROG="
        ];
      postPatch =
        (old.postPatch or "")
        + ''
          sed -i "s|BASIC_CFLAGS += -DSHELL_PATH=.*|BASIC_CFLAGS += -DSHELL_PATH='\"/bin/bash\"'|" Makefile
          substituteInPlace run-command.c \
            --replace-fail 'if (is_executable(buf.buf))' 'if (!access(buf.buf, F_OK))'

          # WASIX has no sessions, so libc setsid() returns EINVAL; daemonize()
          # (git gc --auto) dies on any setsid failure. Tolerate the WASIX errno.
          substituteInPlace setup.c \
            --replace-fail 'if (setsid() == -1)' 'if (setsid() == -1 && errno != EINVAL)'

          mkdir -p wasix-compat
          cp ${./wasix-compat/unistd.h} wasix-compat/unistd.h
          cp ${./wasix-compat/proc.c} wasix-compat/proc.c
        '';
      # wasix-compat shim + explicit -lz (git's Makefile omits -lz on this target)
      # go through NIX_* so the cc-wrapper injects them with correct ordering. The
      # shim lib is built in preConfigure, before any link consumes -lwasix-compat.
      env =
        (old.env or {})
        // {
          NIX_CFLAGS_COMPILE = ((old.env or {}).NIX_CFLAGS_COMPILE or "") + " -Iwasix-compat";
          NIX_LDFLAGS = ((old.env or {}).NIX_LDFLAGS or "") + " -Lwasix-compat -lwasix-compat -lz";
          # fork() needs asyncified binaries. wasixcc only asyncifies in the off
          # profile on its own; these extra wasm-opt flags (which imply running
          # wasm-opt) apply the pass to every linked output here too.
          WASIXCC_WASM_OPT_FLAGS = "--asyncify:-O2";
        };
      preConfigure =
        (old.preConfigure or "")
        + ''
          $CC -c wasix-compat/proc.c -o wasix-compat/proc.o
          $AR rcs wasix-compat/libwasix-compat.a wasix-compat/proc.o

          # Derive curl's link flags from curl-config rather than hand-typing them, so they track
          # curl's transitive deps (brotli/zstd/openssl/zlib). curl-config is a target buildInput
          # (not on $PATH), referenced by store path; it's a build-platform script emitting the
          # target flags, including libcurl.a's Libs.private.
          export CURL_LDFLAGS="$(${packages.sameProfile.lib.getExe' packages.sameProfile.curl.dev "curl-config"} --static-libs)"
        '';
      postInstall =
        (lib.replaceStrings [''rm "$out/$prog"''] [''rm -f "$out/$prog"''] (old.postInstall or ""))
        + ''
          mv "$out/bin/git" "$out/bin/git.wasm"

          # git's subcommands are aliases (bin/git-* and libexec/git-core/git-* are
          # `→ git` symlinks; libexec/git-core/git is a 2nd full copy). Renaming git
          # → git.wasm dangles those, so repoint them. webc preserves symlinks
          # (wasmerio/wasmer#6653), so aliases stay links; git's argv[0] dispatch
          # routes git-add etc. Real helpers (git-remote-http, …) keep their names.
          ln -sf ../../bin/git.wasm "$out/libexec/git-core/git"
          for f in "$out/bin/"* "$out/libexec/git-core/"*; do
            name=''${f##*/}
            [ "$name" = "git.wasm" ] && continue
            [ "$name" = "git" ] && continue

            if [ -L "$f" ] && [ "$(readlink "$f")" = "git" ]; then
              case "$f" in
                "$out/bin/"*) ln -sf git.wasm "$f" ;;
                *) ln -sf ../../bin/git.wasm "$f" ;;
              esac
            fi
          done
        '';
    })
)
