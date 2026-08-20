{
  final,
  helpers,
  prev,
  ...
}:
helpers.libTweaks {
  buildInputs = [
    final.bzip2
    final.boost
    final.llhttp
  ];
  env = {
    AWS_LC_SYS_NO_JITTER_ENTROPY = "1";
    AWS_LC_SYS_CFLAGS = "-DOPENSSL_NO_TTY";
    CXXFLAGS = "-pthread -isystem ${final.boost.dev}/include -DBOOST_ALL_NO_LIB";
    RUSTFLAGS = final.lib.concatStringsSep " " [
      "-Ctarget-feature=+crt-static"
      "-Cforce-frame-pointers=yes"
      "-Lnative=${final.lib.getLib final.bzip2}/lib"
      "-Lnative=${final.lib.getLib final.boost}/lib"
      "-Lnative=${final.llhttp}/lib"
      "-Lnative=${final.buildPackages.wasix-sysroot}/sysroot-eh/lib/wasm32-wasi"
      "-Clink-arg=-lboost_url"
      "-Clink-arg=-lboost_context"
      "-Clink-arg=-lc++abi"
      "-Clink-arg=-lunwind"
    ];
  };
  patches = [
    ./wasi-os-str.patch
    ./wasi-client.patch
  ];
  postPatch = ''
    cp Cargo.lock "$cargoDepsCopy/Cargo.lock"
  '';
  postInstall = ''
    ${final.lib.getExe' final.buildPackages.binaryen "wasm-opt"} "$out/bin/attic.wasm" \
      --enable-bulk-memory --enable-threads --enable-reference-types \
      --enable-exception-handling --no-validation --translate-to-exnref \
      -o "$out/bin/attic.wasm.exnref"
    mv "$out/bin/attic.wasm.exnref" "$out/bin/attic.wasm"
  '';
  passthru.wasix.shipped = true;
  passthru.wasmer = {
    name = "attic-client";
    entrypoint = "attic";
    version = v: let
      d = builtins.match ".*-unstable-([0-9]{4})-([0-9]{2})-([0-9]{2})" v;
    in
      assert final.lib.assertMsg (d != null) "attic-client: version ${v} is not <ver>-unstable-YYYY-MM-DD"; "0.0.${final.lib.concatStrings d}";
  };
}
(prev.attic-client.override {
  nixVersions.nix_2_34 = final.nix;
})
