{
  prev,
  final,
  helpers,
  preferredProfilePackages,
  ...
}:
helpers.libTweaks {
  passthru.wasix.shipped = true;
  # The backend loads extensions with dlopen, and only the PIC sysroots ship
  # <dlfcn.h>.
  passthru.wasix.supportedProfiles = helpers.profiles.pic;
  passthru.wasmer = {
    entrypoint = "postgres";
    autoSelfMount = true;
    # popen() runs `/bin/sh -c`, which initdb and pg_ctl use to start the server.
    # icu-data mounts the collation archive at the path icu compiles in.
    dependencies = [
      preferredProfilePackages.bash
      preferredProfilePackages.icu-data
    ];
    # WASIX has no passwd database, and initdb names the bootstrap superuser
    # after geteuid(), which is always 0 here.
    fs."/etc" = final.writeTextDir "passwd" "postgres:x:0:0:PostgreSQL:/:/bin/sh\n";
  };
  meta.mainProgram = "postgres";
  # nixpkgs marks every static build broken because dlopen is stubbed there;
  # the wasix dyld answers it in the PIC profiles.
  meta.broken = false;
  # wasm32-wasi matches no configure template; pick one explicitly.
  configureFlags = old: old ++ ["--with-template=linux"];
  patches = [
    ./patches/0001-skip-the-root-privilege-check-on-wasi.patch
    ./patches/0002-tolerate-EISDIR-when-fsyncing-a-directory.patch
    ./patches/0003-find-my-exec-falls-back-to-the-install-bindir.patch
  ];
  # git's wasix-compat shim: unistd.h declaring fork() + proc.c implementing it
  # via __wasi_proc_fork. postmaster.c needs the declaration to compile at all.
  postPatch = ''
    mkdir -p wasix-compat/sys
    cp ${../git/wasix-compat/unistd.h} wasix-compat/unistd.h
    cp ${../git/wasix-compat/proc.c} wasix-compat/proc.c
    cp ${./wasix-compat/flock.c} wasix-compat/flock.c
    cp ${./wasix-compat/shm.c} wasix-compat/shm.c
    cp ${./wasix-compat/sys/ipc.h} wasix-compat/sys/ipc.h
    cp ${./wasix-compat/sys/shm.h} wasix-compat/sys/shm.h
  '';
  # wasm-ld keeps the pg_config path strings that -flto --gc-sections drops
  # natively, so each output ends up referencing every other one. The webc takes
  # one command per bin/*.wasm, and the unsuffixed link is what find_other_exec
  # resolves when initdb and pg_ctl look for their sibling program.
  postInstall = ''
    remove-references-to -t "$dev" -t "$doc" -t "$man" "$out"/bin/* "$out"/lib/*.so
    remove-references-to -t "$out" -t "$dev" -t "$doc" -t "$man" "$lib"/lib/*.so*

    for program in "$out/bin/"*; do
      mv "$program" "$program.wasm"
      ln -s "''${program##*/}.wasm" "$program"
    done
  '';
  # The wasix-compat shims and WASIX_BINDIR go through NIX_* so the cc-wrapper
  # injects them into every compile and link, with absolute paths because
  # postgres recurses into subdirectories. ICU is C++, which a C link supplies
  # no runtime for.
  preConfigure = ''
    $CC -Iwasix-compat -c wasix-compat/proc.c -o wasix-compat/proc.o
    $CC -Iwasix-compat -c wasix-compat/flock.c -o wasix-compat/flock.o
    $CC -Iwasix-compat -c wasix-compat/shm.c -o wasix-compat/shm.o
    $AR rcs wasix-compat/libwasix-compat.a wasix-compat/proc.o wasix-compat/flock.o wasix-compat/shm.o
    export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -I$PWD/wasix-compat -DWASIX_BINDIR=\"$out/bin\""
    export NIX_LDFLAGS="$NIX_LDFLAGS -L$PWD/wasix-compat -lwasix-compat -lc++ -lc++abi -lunwind"
  '';
} (prev.postgresql.override {
  # curl carries only the OAuth flow and a static libpq fails its
  # curl_multi_init probe; GSSAPI has no krb5 built for wasix.
  curlSupport = false;
  gssSupport = false;
  # nixpkgs sets libuuid null off Linux; the overlay util-linux ships libuuid only.
  libuuid = final.util-linux;
  tzdata = final.buildPackages.tzdata;
  # nixpkgs bakes `${stdenv.cc.libc}/bin/locale` into pg_import_system_collations,
  # and the wasix stdenv has cc.libc = null. No wasm locale binary exists.
  stdenv =
    final.stdenv
    // {
      cc = final.stdenv.cc // {libc = "/nonexistent-wasix-has-no-glibc";};
      hostPlatform =
        final.stdenv.hostPlatform
        // {
          extensions = final.stdenv.hostPlatform.extensions // {sharedLibrary = ".so";};
        };
    };
})
