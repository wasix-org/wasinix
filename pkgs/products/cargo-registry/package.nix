{
  lib,
  rustPlatform,
  buildPackages,
  fetchFromGitHub,
  nix-update-script,
}: let
  # Upstream dogfoods the overlay registry. Use its exact resolution with the
  # +wasix suffixes stripped, then let the WASIX rustPlatform reapply the fork
  # sources when this recipe is instantiated in a WASIX package set.
  src = buildPackages.runCommand "wasix-cargo-registry-src" {} ''
    cp -r ${fetchFromGitHub {
      owner = "wasix-org";
      repo = "cargo-registry";
      rev = "0978de01b4d35fa0ff21a3f151655a1125dfa233";
      hash = "sha256-390o7Tmq+rrD5DSy5HOnFlyjkbMO/bVs8kG2j44UpFM=";
    }} "$out"
    chmod -R u+w "$out"
    rm -f "$out"/.cargo/config.toml "$out"/.cargo/config "$out"/Cargo.toml.old "$out"/Cargo.lock.old
    cp ${./Cargo.lock} "$out/Cargo.lock"
  '';

  updateScript = buildPackages.writeShellApplication {
    name = "wasix-cargo-registry-update";
    runtimeInputs = [
      (buildPackages.python3.withPackages (ps: [ps.tomlkit]))
    ];
    text = ''
      pkg=$(git rev-parse --show-toplevel)/pkgs/products/cargo-registry
      PYTHONDONTWRITEBYTECODE=1 python3 "$pkg/update.py" "$@"
    '';
  };
  updateArgs = nix-update-script {extraArgs = ["--flake"];};
in
  rustPlatform.buildRustPackage {
    pname = "wasix-cargo-registry";
    version = "0.1.3";
    inherit src;

    cargoHash = "sha256-VIB9xziuRrtbJefUOqlHGePw2HfcjD9r84bPq6UdwZ4=";

    passthru.updateScript = {
      command = ["${updateScript}/bin/wasix-cargo-registry-update"] ++ updateArgs;
      commandDrvPaths = [updateScript] ++ map (_: null) updateArgs;
    };

    meta = {
      description = "Overlay cargo registry server";
      homepage = "https://github.com/wasix-org/cargo-registry";
      license = lib.licenses.mit;
      mainProgram = "wasix-cargo-registry";
    };
  }
