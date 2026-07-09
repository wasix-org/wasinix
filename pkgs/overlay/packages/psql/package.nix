{
  final,
  nixpkgs,
  helpers,
  ...
}: let
  lib = final.lib;
  dropShlibClean = lib.replaceStrings ["rm -rfv $dev/lib/*_shlib.a"] [""];
in
  helpers.wasmRename {wasmName = "psql";} (
    helpers.libTweaks {
      passthru.wasix = {
        shipped = true;
        supportedProfiles = helpers.profiles.withEh;
      };
      pname = "psql";
      meta = {
        mainProgram = "psql";
        description = "PostgreSQL interactive terminal";
      };
      patches = [./patches/0001-skip-system-psqlrc-lookup-on-wasi.patch];
      postBuild = ''
        make -C src/bin/psql
      '';
      installPhase = _:
        dropShlibClean ''
          runHook preInstall

          make -C src/bin/psql install

          runHook postInstall
        '';
      postInstall = ''
        rm -rf "$out/share"
      '';
      buildInputs =
        lib.filter
        (i: !lib.elem (i.pname or i.name or "") ["curl" "gettext" "libkrb5" "openssl"]);
      nativeBuildInputs =
        lib.filter
        (i: (i.pname or i.name or "") != "make-shell-wrapper-hook");
      configureFlags = old:
        (lib.filter (f: f != "--with-openssl") old)
        ++ ["--with-template=linux"];
      env = {
        CPPFLAGS = "-I${lib.getDev final.zlib}/include";
        LDFLAGS = "-L${lib.getLib final.zlib}/lib";
      };
    } (final.callPackage "${nixpkgs}/pkgs/servers/sql/postgresql/libpq.nix" {
      curlSupport = false;
      gssSupport = false;
      nlsSupport = false;
      openssl = final.zlib;
      tzdata = final.buildPackages.tzdata;
    })
  )
