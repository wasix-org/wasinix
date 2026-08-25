{
  dropFlagsByPrefix,
  dropInputsByNameInfix,
  exposePackage,
  extendPackage,
  linkInputs,
  package,
}:
exposePackage (
  extendPackage (package.override {
    libtool = null;
    withModules = false;
    withSystemd = false;
  }) ({
      configureFlags = old:
        dropFlagsByPrefix [
          "--enable-crypt"
          "--enable-overlays"
          "--enable-spasswd"
        ]
        old
        ++ [
          "--disable-local"
          "--disable-slapd"
          "--disable-overlays"
          "--disable-spasswd"
          "--without-cyrus-sasl"
        ];
      buildPhase = _: ''
        runHook preBuild
        make $makeFlags -C include
        make $makeFlags -C libraries/liblber liblber.la
        make $makeFlags -C libraries/libldap libldap.la
        runHook postBuild
      '';
      postBuild = _: "";
      installPhase = _: ''
        runHook preInstall
        mkdir -p "$out" "$dev/lib/pkgconfig" "$man" "$devdoc"
        make $installFlags -C include install
        make $installFlags -C libraries/liblber install
        make $installFlags -C libraries/libldap install
        install -m644 libraries/liblber/lber.pc libraries/libldap/ldap.pc "$dev/lib/pkgconfig/"
        runHook postInstall
      '';
      preFixup = _: "";
    }
    // linkInputs (dropInputsByNameInfix ["cyrus-sasl"]))
)
