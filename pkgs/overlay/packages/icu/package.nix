# Every nixpkgs icu major, tweaked for wasix: data as a loadable archive (not
# linked into every binary), no host tools, and configure support for the
# "unknown" platform wasm32 maps to.
let
  versions = import ./versions.nix;
in {
  names = ["icu"] ++ map (v: "icu${v}") versions;
  packages = {
    final,
    prev,
    helpers,
    ...
  }: let
    inherit (prev) lib;
    tweak = base:
      helpers.libTweaks {
        configureFlags = [
          "--with-data-packaging=archive"
          "--disable-extras"
          "--disable-samples"
          "--disable-tests"
          "--disable-tools"
        ];
        # The stock default data dir is $out's store path, unresolvable inside
        # a wasm guest. Point it at the stable path the icu-data webcs mount;
        # ICU_DATA still overrides at runtime. ICU_DATA_DIR takes precedence
        # over the makefile-provided U_ICU_DATA_DEFAULT_DIR (putil.cpp).
        env.CPPFLAGS = "-DICU_DATA_DIR='\"/share/icu/${base.version}\"'";
        postPatch =
          ''
            patch -p1 < ${./patches/no-tzname-on-unknown.patch}
          ''
          # icu 63-66 vendor a double-conversion that #errors on unlisted
          # targets; wasm32 has IEEE doubles, so whitelist it (what icu 67 did
          # upstream). icu 60 predates the vendoring.
          + lib.optionalString
          (lib.versionAtLeast base.version "63" && lib.versionOlder base.version "67") ''
            substituteInPlace i18n/double-conversion-utils.h \
              --replace-fail '#if defined(_M_X64) || defined(__x86_64__) ||' \
                '#if defined(__wasm32__) || defined(_M_X64) || defined(__x86_64__) ||'
          '';
        preConfigure = ''
          cp config/mh-linux config/mh-unknown
        '';
        # icu < 67 cannot package data with --disable-tools ("this ICU cannot
        # build its own data"); install the tarball's prebuilt little-endian
        # archive, which is what >= 67 repackages anyway.
        postInstall = lib.optionalString (lib.versionOlder base.version "67") ''
          install -Dm444 -t "$out/share/icu/${base.version}" data/in/icudt*l.dat
        '';
      }
      base;
  in
    # nixpkgs' `icu` aliases the default icuNN through the fixpoint, so
    # tweaking prev.icu would re-tweak our icuNN. Follow the alias instead.
    {icu = final."icu${lib.versions.major prev.icu.version}";}
    // lib.genAttrs (map (v: "icu${v}") versions) (n: tweak prev.${n});
}
