{
  exposePackage,
  packageSet,
}:
exposePackage (packageSet.callPackage ({rustPlatform}:
    rustPlatform.buildRustPackage {
      pname = "cargo-registry-wire";
      version = "0.1.0";

      src = ../../../../tools/wasinix/cargo-registry-wire;
      cargoLock.lockFile = ../../../../tools/wasinix/cargo-registry-wire/Cargo.lock;

      doCheck = true;

      passthru.wasix.supportedProfiles = [];

      meta.mainProgram = "cargo-registry-wire";
    }) {})
