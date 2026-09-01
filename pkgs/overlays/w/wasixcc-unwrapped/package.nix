# The WASIX cc driver. One binary, wasixccenv, dispatching on argv0; the
# toolchain wraps it under each tool name with the sysroot locations baked in.
# The package unit lives here so the WASIX build carries the same fixes as the native
# one the cross sets compile with.
{
  exposePackage,
  packageSet,
}:
exposePackage (packageSet.callPackage ({
    lib,
    rustPlatform,
    fetchFromGitHub,
  }:
    rustPlatform.buildRustPackage (finalAttrs: {
      pname = "wasixcc-unwrapped";
      version = "0.4.6";

      src = fetchFromGitHub {
        owner = "wasix-org";
        repo = "wasixcc";
        tag = "v${finalAttrs.version}";
        hash = "sha256-EGvRhe30+hiMoGSj/+ySAAo0VeeWbAGcYhR5offSyPU=";
      };

      cargoHash = "sha256-urrD15TpT/zzuKXNGNCUhffRmL0VR61I7JK7NKmPzNU=";

      # Export the full symbol table only from dynamically linked modules.
      patches = [./wasixcc-export-dynamic.patch];

      doCheck = true;

      passthru.wasix.supportedProfiles = [];

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/libexec"
        cp "$(find target -type f -path '*/release/wasixccenv' | head -n 1)" "$out/libexec/wasixccenv"
        runHook postInstall
      '';

      meta = {
        description = "Unwrapped WASIX C/C++ compiler driver";
        longDescription = "The unwrapped WASIX C and C++ compiler driver used by the repository's relocatable toolchain.";
        homepage = "https://github.com/wasix-org/wasixcc";
        changelog = "https://github.com/wasix-org/wasixcc/releases/tag/v${finalAttrs.version}";
        license = with lib.licenses; [mit asl20];
      };
    })) {})
