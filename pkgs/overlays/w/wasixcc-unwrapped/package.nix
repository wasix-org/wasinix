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
      version = "0.4.5";

      src = fetchFromGitHub {
        owner = "wasix-org";
        repo = "wasixcc";
        tag = "v${finalAttrs.version}";
        hash = "sha256-dCBNXceJO9Wx91o7+g/iVzHiCeanC71NPk0PUsf4xN0=";
      };

      cargoHash = "sha256-6f0LnlsAKK/VywTFfjPIMBmG+Ht1q2ItRSvmKkd8qpU=";

      # Translate GNU C++ and OpenMP inputs for shared modules, avoid executable-only
      # inputs for non-executable links, and export the full symbol table only from
      # dynamically linked modules.
      patches = [
        ./wasixcc-map-libstdcxx-to-libcxx.patch
        ./wasixcc-openmp-link.patch
        ./wasixcc-relocatable-link-passthrough.patch
        ./wasixcc-rlib-linker-input.patch
        ./wasixcc-nodefaultlibs.patch
        ./wasixcc-nostartfiles.patch
        ./wasixcc-export-dynamic.patch
      ];

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
