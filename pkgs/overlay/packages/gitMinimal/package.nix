# Built in the default profile; execs the off-profile bash at runtime via
# SHELL_PATH=/bin/bash, mounted from the bash webc dependency (see the wasmer
# block) rather than bundled. gnugrep/gnused are our wasix builds (git bakes
# their paths into scripts); gawk/coreutils are build tools.
{
  final,
  prev,
  preferredPackages,
  ...
}: let
  lib = final.lib;
  bash = preferredPackages.bash;
in
  (prev.gitMinimal.override {
    gnugrep = final.grep;
    gnused = final.sed;
    gawk = final.buildPackages.gawk;
    coreutils = final.buildPackages.coreutils;
    gettext = final.gettext;
    inherit bash;
    # makeWrapper only wraps the Perl subcommands gitMinimal omits.
    makeWrapper = null;
    nlsSupport = false;
    doInstallCheck = false;
  })
  .overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        inherit bash;
        # wasmer packaging (name "git" comes from meta.mainProgram; the rest
        # is derived):
        wasmer = {
          # certs for HTTPS clones, mounted where git/openssl look for them.
          fs."/etc/ssl" = "${final.cacert}/etc/ssl";
          commandEnv.git = {
            SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
            GIT_SSL_CAINFO = "/etc/ssl/certs/ca-bundle.crt";
          };
          # git execs SHELL_PATH=/bin/bash (set below); wasmer's use_package
          # mounts this dependency's `bash` command there at load, so bash is
          # not bundled into git's webc. webcRefOf derives "owner/name"@version
          # from the versionless ref.
          dependencies = [bash];
          # git execs its libexec helpers at absolute /nix/store paths; mount
          # whatever git.wasm embeds (bash is no longer embedded).
          autoSelfMount = true;
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
        export CURL_LDFLAGS="$(${final.curl.dev}/bin/curl-config --static-libs)"
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
