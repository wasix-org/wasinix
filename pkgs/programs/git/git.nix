{
  lib,
  toolchain,
  bash,
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
  inherit bash;
  # makeWrapper only wraps the Perl subcommands gitMinimal omits.
  makeWrapper = null;
  inherit
    openssl
    curl
    expat
    libiconv
    ;
  nlsSupport = false;
  doInstallCheck = false;
  stdenv = toolchain.stdenv;
}).overrideAttrs
(old: {
  passthru =
    (old.passthru or {})
    // {
      inherit bash;
    };
  makeFlags =
    old.makeFlags
    ++ [
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

  # buildInputs (-I/-L for zlib-ng/openssl/curl/expat/…) now propagate via the
  # cc-wrapper stdenv. The local wasix-compat shim and an explicit -lz (git's
  # Makefile doesn't emit -lz on this target) go through NIX_* so the cc-wrapper
  # injects them into every compile/link with correct ordering. The shim lib is
  # built in preConfigure below, before any link consumes -lwasix-compat.
  env =
    (old.env or {})
    // {
      NIX_CFLAGS_COMPILE = ((old.env or {}).NIX_CFLAGS_COMPILE or "") + " -Iwasix-compat";
      NIX_LDFLAGS = ((old.env or {}).NIX_LDFLAGS or "") + " -Lwasix-compat -lwasix-compat -lz";
    };

  preConfigure =
    (old.preConfigure or "")
    + ''
      # Compile the wasix-compat shim (process fns missing from WASIX libc).
      $CC -c wasix-compat/proc.c -o wasix-compat/proc.o
      $AR rcs wasix-compat/libwasix-compat.a wasix-compat/proc.o
    '';
  configureFlags =
    (old.configureFlags or [])
    ++ [
      "--host=${toolchain.host}"
    ];

  # postConfigure =
  #   (old.postConfigure or "")
  #   + ''
  #     echo 'LDFLAGS += -Lwasix-compat -lwasix-compat' >> config.mak.autogen
  #   '';

  postInstall =
    (lib.replaceStrings [''rm "$out/$prog"''] [''rm -f "$out/$prog"''] (old.postInstall or ""))
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
