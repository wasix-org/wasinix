# libpq via nixpkgs' standalone libpq.nix. tzdata is a build-platform tool.
{
  final,
  prev,
  nixpkgs,
  helpers,
  ...
}: let
  lib = final.lib;
  dropShlibClean = lib.replaceStrings ["rm -rfv $dev/lib/*_shlib.a"] [""];
in
  (final.callPackage "${nixpkgs}/pkgs/servers/sql/postgresql/libpq.nix" {
    curlSupport = false;
    gssSupport = false;
    nlsSupport = false;
    openssl = final.openssl;
    tzdata = final.buildPackages.tzdata;
  })
  .overrideAttrs (old: {
    doCheck = false;
    # postgres error handling is built on sigsetjmp, which the off sysroot's
    # <setjmp.h> doesn't declare.
    passthru =
      (old.passthru or {})
      // {wasix.supportedProfiles = helpers.profiles.withEh;};
    installPhase = dropShlibClean (old.installPhase or "");
    buildInputs =
      lib.filter
      (i: !lib.elem (i.pname or i.name or "") ["curl" "gettext" "libkrb5"])
      (old.buildInputs or []);
    nativeBuildInputs =
      lib.filter
      (i: (i.pname or i.name or "") != "make-shell-wrapper-hook")
      (old.nativeBuildInputs or []);
    configureFlags = (old.configureFlags or []) ++ ["--with-template=linux"];
    env =
      (old.env or {})
      // {
        CPPFLAGS = "-I${lib.getDev final.zlib}/include";
        LDFLAGS = "-L${lib.getLib final.zlib}/lib";
      };
    postInstall =
      (dropShlibClean (old.postInstall or ""))
      + "\n"
      + ''
        pc="$dev/lib/pkgconfig/libpq.pc"
        if [ -f "$pc" ]; then
          libs="$(sed -n 's/^Libs: //p' "$pc")"
          libs_private="$(sed -n 's/^Libs.private: //p' "$pc")"
          libs_private="$(printf '%s' "$libs_private" | sed 's/-lpgcommon\b/-lpgcommon_shlib/g; s/-lpgport\b/-lpgport_shlib/g')"
          sed -i "s|^Libs: .*|Libs: $libs $libs_private|" "$pc"
          sed -i 's|^Libs.private: .*|Libs.private: |' "$pc"
        fi
      '';
  })
