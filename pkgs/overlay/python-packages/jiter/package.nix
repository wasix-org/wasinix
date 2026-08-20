# jiter for wasix. maturin/pyo3 wheel (fast JSON parser; anthropic/openai core).
#
# locks/: upstream commits no Cargo.lock, so nixpkgs carries one for the version
# it packages, and an older release needs the lock published with that release
# (its sdist carries one, its git tag does not). The entry marks `lockInPackage`
# so the rebase vendors from the file named here rather than from the src it
# repointed (pkgs/set/rust-platform.nix).
{
  pyprev,
  helpers,
  final,
  lib,
  ...
}: let
  lock = ./locks/${pyprev.jiter.version}.lock;
in
  helpers.extendPackage pyprev.jiter ({
      maturinBuildFlags = ["--features" "pyo3/extension-module"];
    }
    // lib.optionalAttrs (builtins.pathExists lock) {
      cargoDeps = final.rustPlatform.importCargoLock {
        lockFileContents = builtins.readFile lock;
      };
      # cargoSetupPostUnpackHook has already installed the vendor's lock, read
      # only, so this replaces the file rather than writing through it.
      postPatch = ''
        rm -f Cargo.lock
        cp ${lock} Cargo.lock
      '';
    })
