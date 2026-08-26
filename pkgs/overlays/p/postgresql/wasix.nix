{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  profileSets,
}:
exposeWasixPackage (
  (extendPackage (package.override {
      # curl carries only the OAuth flow and a static libpq fails its
      # curl_multi_init probe; GSSAPI has no krb5 built for wasix.
      curlSupport = false;
      gssSupport = false;
      # nixpkgs sets libuuid null off Linux; the overlay util-linux ships libuuid only.
      libuuid = packages.sameProfile.util-linux;
      tzdata = packages.sameProfile.buildPackages.tzdata;
      # nixpkgs bakes the libc locale executable's store path into pg_import_system_collations,
      # and the wasix stdenv has cc.libc = null. No wasm locale binary exists.
      stdenv =
        packages.sameProfile.stdenv
        // {
          cc = packages.sameProfile.stdenv.cc // {libc = "/nonexistent-wasix-has-no-glibc";};
          hostPlatform =
            packages.sameProfile.stdenv.hostPlatform
            // {
              extensions = packages.sameProfile.stdenv.hostPlatform.extensions // {sharedLibrary = ".so";};
            };
        };
    }) {
      passthru.wasix.supportedProfiles = profileSets.pic;
      passthru.wasinix.shipped = true;
      # The backend loads extensions with dlopen, and only the PIC sysroots ship
      # <dlfcn.h>.
      meta.mainProgram = "postgres";
      # nixpkgs marks every static build broken because dlopen is stubbed there;
      # the wasix dyld answers it in the PIC profiles.
      meta.broken = false;
      # wasm32-wasi matches no configure template; pick one explicitly.
      configureFlags = old: old ++ ["--with-template=linux"];
      patches = [./patches/0001-skip-the-root-privilege-check-on-wasi.patch];
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
      # one command per bin/*.wasm; the unsuffixed link keeps find_other_exec working
      # for a binary run from the store rather than as a webc command.
      postInstall = ''
        remove-references-to -t "$dev" -t "$doc" -t "$man" "$out"/bin/* "$out"/lib/*.so
        remove-references-to -t "$out" -t "$dev" -t "$doc" -t "$man" "$lib"/lib/*.so*

        for program in "$out/bin/"*; do
          mv "$program" "$program.wasm"
          ln -s "''${program##*/}.wasm" "$program"
        done
      '';
      # The wasix-compat shims go through NIX_* so the cc-wrapper injects them into
      # every compile and link, with absolute paths because postgres recurses into
      # subdirectories. ICU is C++, which a C link supplies no runtime for.
      preConfigure = ''
        $CC -Iwasix-compat -c wasix-compat/proc.c -o wasix-compat/proc.o
        $CC -Iwasix-compat -c wasix-compat/flock.c -o wasix-compat/flock.o
        $CC -Iwasix-compat -c wasix-compat/shm.c -o wasix-compat/shm.o
        $AR rcs wasix-compat/libwasix-compat.a wasix-compat/proc.o wasix-compat/flock.o wasix-compat/shm.o
        export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -I$PWD/wasix-compat"
        export NIX_LDFLAGS="$NIX_LDFLAGS -L$PWD/wasix-compat -lwasix-compat -lc++ -lc++abi -lunwind"
      '';
    })
# wasmer places every command at /bin, so PATH is all find_my_exec needs to
# resolve the running program and its siblings. my_exec_path is then /bin/<cmd>,
# and postgres derives SHAREDIR and PKGLIBDIR relative to it, which is why those
# two mount at stable paths rather than the store path a self-mount would need.
.overrideAttrs (finalAttrs: prevAttrs: {
    passthru =
      prevAttrs.passthru
      // {
        wasmer = {
          entrypoint = "postgres";
          env.PATH = "/bin";
          commands = map (name:
            {inherit name;}
            // packages.sameProfile.lib.optionalAttrs (name == "psql") {global = false;}) [
            "clusterdb"
            "createdb"
            "createuser"
            "dropdb"
            "dropuser"
            "initdb"
            "oid2name"
            "pg_amcheck"
            "pg_archivecleanup"
            "pg_basebackup"
            "pg_checksums"
            "pg_combinebackup"
            "pg_controldata"
            "pg_createsubscriber"
            "pg_ctl"
            "pg_dump"
            "pg_dumpall"
            "pg_isready"
            "pg_receivewal"
            "pg_recvlogical"
            "pg_resetwal"
            "pg_restore"
            "pg_rewind"
            "pg_test_fsync"
            "pg_test_timing"
            "pg_upgrade"
            "pg_verifybackup"
            "pg_waldump"
            "pg_walsummary"
            "pgbench"
            "postgres"
            "psql"
            "reindexdb"
            "vacuumdb"
            "vacuumlo"
          ];
          # popen() runs `/bin/sh -c`, which initdb and pg_ctl use to start the
          # server. icu-data carries the collation archive icu compiles a path to.
          dependencies = [
            packages.wasix.preferred.bash
            packages.wasix.preferred.icu-data
          ];
          fs = {
            # WASIX has no passwd database, and initdb names the bootstrap
            # superuser after geteuid(), which is always 0 here.
            "/etc" = packages.sameProfile.writeTextDir "passwd" "postgres:x:0:0:PostgreSQL:/:/bin/sh\n";
            "/share/postgresql" = "${finalAttrs.finalPackage}/share/postgresql";
            "/lib" = "${finalAttrs.finalPackage}/lib";
          };
          # Read through paths the build baked in rather than derived ones: the
          # dynamic libpq, the zoneinfo --with-system-tzdata names, and terminfo.
          selfMounts = [
            finalAttrs.finalPackage.lib
            packages.sameProfile.buildPackages.tzdata
            packages.sameProfile.ncurses
            packages.sameProfile.openssl
            # libxml2's first output is `bin`; the binaries name `out`.
            packages.sameProfile.libxml2.out
          ];
        };
      };
  })
)
