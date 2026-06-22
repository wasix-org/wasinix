{
  lib,
  toolchain,
  sh,
  gitMinimal,
  zlib-ng,
  openssl,
  curl,
  expat,
  libiconv,
  gnugrep,
  gnused,
  gawk,
  gettext,
  coreutils,
}:
(gitMinimal.override {
  inherit
    gnugrep
    gnused
    gawk
    gettext
    coreutils
    zlib-ng
    ;
  # makeWrapper wraps git in a bash script; bash is not packaged yet so null both.
  bash = null;
  makeWrapper = null;
  inherit
    openssl
    curl
    expat
    libiconv
    ;
  nlsSupport = false;
  doInstallCheck = false;
}).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit sh;
    };
    makeFlags = old.makeFlags ++ [
      # nixpkgs cross builds set these to indicate missing symbols on plain WASI;
      # WASIX libc provides both, so clear them to re-enable the native path.
      "NO_INET_NTOP="
      "NO_INET_PTON="
      "NO_TCLTK=YesPlease"
      # `git commit` fails with "invalid object" because WASIX unlink()
      # silently no-ops on files in .git/objects/aa/. Git writes objects as
      # link(tmp_obj_X, hash) + unlink(tmp_obj_X), so both files end up in
      # the dir. This flag switches the writer to rename().
      "OBJECT_CREATION_USES_RENAMES=YesPlease"
      # sysinfo() is in WASIX headers but absent from libc.a.
      "HAVE_SYSINFO="
      # configure cannot run WASM test binaries; force-enable curl and OpenSSL.
      "NO_CURL="
      "NO_OPENSSL="
      "CURL_LDFLAGS=-lcurl -lssl -lcrypto"
      "OPENSSL_LINK=-lssl -lcrypto"
    ];

    postPatch = (old.postPatch or "") + ''
      sed -i "s|BASIC_CFLAGS += -DSHELL_PATH=.*|BASIC_CFLAGS += -DSHELL_PATH='\"${sh}/bin/sh.wasm\"'|" Makefile
      substituteInPlace run-command.c \
        --replace-fail 'if (is_executable(buf.buf))' 'if (!access(buf.buf, F_OK))'

      mkdir -p wasix-compat
      cp ${./wasix-compat/unistd.h} wasix-compat/unistd.h
      cp ${./wasix-compat/proc.c} wasix-compat/proc.c
    '';

    preConfigure = (old.preConfigure or "") + ''
      ${toolchain.commonPreConfigure}

      # Without this, for some reason, it doesn't see the compiler/linker flags.
      # And without -lz, it doesn't find libz-ng, even though it should be in buildInputs.
      # TODO: Figure out why
      export CPPFLAGS="-Iwasix-compat $NIX_CFLAGS_COMPILE"
      export LDFLAGS="-Lwasix-compat -lwasix-compat $NIX_LDFLAGS -lz"

      # Compile our shims
      $CC $CPPFLAGS -c wasix-compat/proc.c -o wasix-compat/proc.o
      $AR rcs wasix-compat/libwasix-compat.a wasix-compat/proc.o
    '';
    configureFlags = (old.configureFlags or [ ]) ++ [
      "--host=${toolchain.host}"
    ];

    # postConfigure =
    #   (old.postConfigure or "")
    #   + ''
    #     echo 'LDFLAGS += -Lwasix-compat -lwasix-compat' >> config.mak.autogen
    #   '';

    postInstall =
      (lib.replaceStrings [ ''rm "$out/$prog"'' ] [ ''rm -f "$out/$prog"'' ] (old.postInstall or ""))
      + ''
        mv "$out/bin/git" "$out/bin/git.wasm"

        asyncify() {
          ${toolchain.binaryen}/bin/wasm-opt --asyncify -O2 "$1" -o "$1"
        }

        asyncify "$out/bin/git.wasm"

        # git installs its subcommands as aliases of the main binary: bin/git-*
        # and libexec/git-core/git-* are `→ git` symlinks, and libexec/git-core/git
        # is a second full copy. Renaming git → git.wasm dangles those symlinks,
        # so repoint them at the asyncified wasm. webc preserves symlinks since
        # wasmerio/wasmer#6653 (webc 12), so each alias stays a link instead of
        # deref'ing into a ~6.5MB copy of git.wasm; git's own argv[0] dispatch
        # then routes `git-add` etc. through the binary as usual. Real helpers
        # (git-remote-http, ...) are standalone wasm binaries, asyncified in place.
        ln -sf ../../bin/git.wasm "$out/libexec/git-core/git"
        for f in "$out/bin/"* "$out/libexec/git-core/"*; do
          name=''${f##*/}
          [ "$name" = "git.wasm" ] && continue
          [ "$name" = "git" ] && continue

          if [ -L "$f" ] && [ "$(readlink "$f")" = "git" ]; then
            case "$f" in
              "$out/bin/"*) ln -sf git.wasm "$f" ;;
              *)            ln -sf ../../bin/git.wasm "$f" ;;
            esac
          elif [ -f "$f" ] && [ ! -L "$f" ] && od -An -N4 -tx1 "$f" | grep -q "00 61 73 6d"; then
            asyncify "$f"
          fi
        done
      '';
  })
