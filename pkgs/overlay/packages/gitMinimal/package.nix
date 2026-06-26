# Built in the default profile; embeds the off-profile bash.wasm at runtime via
# preferredPackages.bash (the cross-profile resolution). zlib-ng/openssl/curl/
# expat/libiconv auto-thread; gnugrep/gnused are our wasix builds (git bakes
# their paths into scripts); gawk/coreutils are build-platform tools.
{
  final,
  prev,
  foundation,
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
        # wasmer packaging deviations (name "git" comes from meta.mainProgram;
        # version/description/license/commands are all derived):
        wasmer = {
          owner = "kilyanni";
          # certs for HTTPS clones, mounted where git/openssl look for them.
          fs."/etc/ssl" = "${final.cacert}/etc/ssl";
          commandEnv.git = {
            SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
            GIT_SSL_CAINFO = "/etc/ssl/certs/ca-bundle.crt";
          };
          # git execs its libexec helpers + the off-profile bash.wasm at their
          # absolute /nix/store paths; mount whatever git.wasm embeds.
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
        # configure can't run WASM test binaries; force-enable curl + OpenSSL.
        "NO_CURL="
        "NO_OPENSSL="
        "CURL_LDFLAGS=-lcurl -lssl -lcrypto"
        "OPENSSL_LINK=-lssl -lcrypto"
      ];
    postPatch =
      (old.postPatch or "")
      + ''
        sed -i "s|BASIC_CFLAGS += -DSHELL_PATH=.*|BASIC_CFLAGS += -DSHELL_PATH='\"${bash}/bin/bash.wasm\"'|" Makefile
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
      };
    preConfigure =
      (old.preConfigure or "")
      + ''
        $CC -c wasix-compat/proc.c -o wasix-compat/proc.o
        $AR rcs wasix-compat/libwasix-compat.a wasix-compat/proc.o
      '';
    postInstall =
      (lib.replaceStrings [''rm "$out/$prog"''] [''rm -f "$out/$prog"''] (old.postInstall or ""))
      + ''
        mv "$out/bin/git" "$out/bin/git.wasm"

        asyncify() {
          ${foundation.binaryen}/bin/wasm-opt --asyncify -O2 "$1" -o "$1"
        }
        asyncify "$out/bin/git.wasm"

        # git's subcommands are aliases (bin/git-* and libexec/git-core/git-* are
        # `→ git` symlinks; libexec/git-core/git is a 2nd full copy). Renaming git
        # → git.wasm dangles those, so repoint them at the asyncified wasm. webc
        # preserves symlinks (wasmerio/wasmer#6653), so aliases stay links; git's
        # argv[0] dispatch routes git-add etc. Real helpers (git-remote-http, …)
        # are standalone wasm binaries, asyncified in place.
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
          elif [ -f "$f" ] && [ ! -L "$f" ] && od -An -N4 -tx1 "$f" | grep -q "00 61 73 6d"; then
            asyncify "$f"
          fi
        done
      '';
  })
