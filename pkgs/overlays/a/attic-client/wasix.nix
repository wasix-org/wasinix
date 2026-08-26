{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
}:
exposeWasixPackage (
  extendPackage (package.override {
    nixVersions.nix_2_34 = packages.sameProfile.nix;
  }) {
    passthru = {
      wasix.supportedProfiles = ["eh" "ehpic"];
      wasinix.shipped = true;
      wasmer = {
        name = "attic-client";
        entrypoint = "attic";
        version = v: let
          d = builtins.match ".*-unstable-([0-9]{4})-([0-9]{2})-([0-9]{2})" v;
        in
          assert packages.sameProfile.lib.assertMsg (d != null) "attic-client: version ${v} is not <ver>-unstable-YYYY-MM-DD"; "0.0.${packages.sameProfile.lib.concatStrings d}";
      };
    };
    buildInputs = [
      packages.sameProfile.bzip2
      packages.sameProfile.boost
      packages.sameProfile.llhttp
    ];
    env = {
      AWS_LC_SYS_NO_JITTER_ENTROPY = "1";
      AWS_LC_SYS_CFLAGS = "-DOPENSSL_NO_TTY";
    };
    patches = [
      ./wasi-os-str.patch
      ./wasi-client.patch
    ];
    postPatch = ''
      cp Cargo.lock "$cargoDepsCopy/Cargo.lock"
    '';
    postInstall = ''
      ${packages.sameProfile.lib.getExe' packages.sameProfile.buildPackages.binaryen "wasm-opt"} "$out/bin/attic.wasm" \
        --enable-bulk-memory --enable-threads --enable-reference-types \
        --enable-exception-handling --no-validation --translate-to-exnref \
        -o "$out/bin/attic.wasm.exnref"
      mv "$out/bin/attic.wasm.exnref" "$out/bin/attic.wasm"
    '';
  }
)
