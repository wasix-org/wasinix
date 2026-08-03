# The overlay cargo registry server (wasix-org/cargo-registry), cross-built to
# WASIX and shipped as a webc: the same program the native pkgs/cargo-registry
# builds for the host loop, but as it actually deploys (wasmer Edge). Its wasix
# fork stack (tokio/mio/socket2/cc/getrandom + stock ring/rustls) is patched at
# vendor time like any other rust package here.
#
# `Cargo.lock` is upstream's, transformed for our vendor: upstream dogfoods the
# overlay, so its lock resolves the fork tree as `<crate>+wasix.N` from
# cargo-registry.wasix.org, which fetchCargoVendor (crates.io) can't fetch.
# derive-lock.py strips the `+wasix.N` suffix off every version and dep ref and
# restores the crates.io checksum, giving the plain resolution cargo would have
# produced without the overlay: the exact versions upstream ships (mio 1.0.3,
# tokio 1.47.0, ...), NOT re-resolved forward. Our vendor-time patches then
# re-apply the fork content. The `wasix` crate (mio's fork dep) survives the
# strip, so the lock already carries it and the patch machinery's lock amend is
# a no-op here.
{
  final,
  nix-update-script,
  ...
}: let
  inherit (final) lib;
  # Drop the overlay-dogfooding config before vendoring (see the native
  # server's default.nix for why); Cargo.lock is our derive-lock.py output.
  src = final.buildPackages.runCommand "wasix-cargo-registry-src" {} ''
    cp -r ${final.fetchFromGitHub {
      owner = "wasix-org";
      repo = "cargo-registry";
      rev = "0978de01b4d35fa0ff21a3f151655a1125dfa233";
      hash = "sha256-390o7Tmq+rrD5DSy5HOnFlyjkbMO/bVs8kG2j44UpFM=";
    }} "$out"
    chmod -R u+w "$out"
    rm -f "$out"/.cargo/config.toml "$out"/.cargo/config "$out"/Cargo.toml.old "$out"/Cargo.lock.old
    cp ${./Cargo.lock} "$out/Cargo.lock"
  '';

  # nix-update (passed as our args) bumps rev + src hash, then this re-derives
  # ./Cargo.lock from the new upstream lock and refreshes cargoHash against it.
  # derive-lock.py needs tomlkit, so the runner carries a python that has it; its
  # stderr lists the +wasix crates so a bump can check each still has a
  # wasix-crate-patches entry or builds stock.
  updateScript = final.buildPackages.writeShellApplication {
    name = "wasix-cargo-registry-update";
    runtimeInputs = [
      final.buildPackages.git
      final.buildPackages.curl
      final.buildPackages.gnugrep
      (final.buildPackages.python3.withPackages (ps: [ps.tomlkit]))
    ];
    text = ''
      pkg=$(git rev-parse --show-toplevel)/pkgs/overlay/packages/cargo-registry

      "$@"

      rev=$(grep -m1 -oE '[0-9a-f]{40}' "$pkg/package.nix")
      curl -sSfL "https://raw.githubusercontent.com/wasix-org/cargo-registry/$rev/Cargo.lock" \
        | python3 "$pkg/derive-lock.py" /dev/stdin > "$pkg/Cargo.lock"

      "$@" --version=skip
    '';
  };
in
  final.rustPlatform.buildRustPackage {
    pname = "wasix-cargo-registry";
    version = "0.1.3";
    inherit src;

    cargoHash = "sha256-VIB9xziuRrtbJefUOqlHGePw2HfcjD9r84bPq6UdwZ4=";

    passthru = {
      # A deployed server, not a version-pinned library, so a bump keeps no
      # outgoing version in the registry-history table.
      wasix = {
        shipped = true;
        retention = "none";
      };
      updateScript = [updateScript] ++ nix-update-script {extraArgs = ["--flake"];};
    };

    meta = {
      description = "Overlay cargo registry server, built to WASIX";
      homepage = "https://github.com/wasix-org/cargo-registry";
      license = lib.licenses.mit;
      mainProgram = "wasix-cargo-registry";
    };
  }
