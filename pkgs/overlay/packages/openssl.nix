# nixpkgs openssl has no wasm Configure target, so drive Configure by hand
# (linux-generic32, static-only).
{
  final,
  prev,
  ...
}:
prev.openssl.overrideAttrs (old: {
  configureScript = "Configure";
  configurePlatforms = [];
  outputs = ["out" "dev"];
  doCheck = false;
  dontDisableStatic = true;
  postInstall = "";
  postFixup = "";
  postPatch = ''
    patchShebangs Configure
    substituteInPlace config --replace-quiet '/usr/bin/env' '${final.buildPackages.coreutils}/bin/env'
  '';
  configurePhase = ''
    runHook preConfigure

    perl ./Configure \
      linux-generic32 \
      no-shared \
      no-module \
      no-tests \
      no-apps \
      no-dgram \
      no-pic \
      no-dso \
      no-afalgeng \
      -DOPENSSL_NO_SECURE_MEMORY \
      --prefix=$out \
      --openssldir=$out/etc/ssl \
      --libdir=lib

    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-1} build_generated build_libs
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib" "$out/etc/ssl" "$dev/include" "$dev/lib/pkgconfig"

    cp libcrypto.a "$out/lib/"
    cp libssl.a "$out/lib/"
    cp -r include/openssl "$dev/include/"

    cat > "$dev/lib/pkgconfig/libcrypto.pc" <<EOF
    prefix=$out
    exec_prefix=\''${prefix}
    libdir=\''${prefix}/lib
    includedir=$dev/include

    Name: OpenSSL-libcrypto
    Description: OpenSSL cryptography library
    Version: ${old.version}
    Libs: -L\''${libdir} -lcrypto
    Cflags: -I\''${includedir}
    EOF

    cat > "$dev/lib/pkgconfig/libssl.pc" <<EOF
    prefix=$out
    exec_prefix=\''${prefix}
    libdir=\''${prefix}/lib
    includedir=$dev/include

    Name: OpenSSL-libssl
    Description: OpenSSL SSL/TLS library
    Version: ${old.version}
    Requires: libcrypto
    Libs: -L\''${libdir} -lssl
    Cflags: -I\''${includedir}
    EOF

    cat > "$dev/lib/pkgconfig/openssl.pc" <<EOF
    prefix=$out
    exec_prefix=\''${prefix}
    libdir=\''${prefix}/lib
    includedir=$dev/include

    Name: OpenSSL
    Description: Secure Sockets Layer and cryptography libraries
    Version: ${old.version}
    Requires: libssl libcrypto
    Libs: -L\''${libdir} -lssl -lcrypto
    Cflags: -I\''${includedir}
    EOF

    runHook postInstall
  '';
})
