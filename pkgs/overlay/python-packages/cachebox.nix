# cachebox (not in nixpkgs): a pyo3/maturin LRU/LFU/TTL cache, pure Rust with no
# C or async stack, so the standard wasix maturin machinery suffices.
{
  pyfinal,
  final,
  ...
}:
pyfinal.buildPythonPackage (finalAttrs: {
  pname = "cachebox";
  version = "6.2.1";
  pyproject = true;

  src = final.fetchFromGitHub {
    owner = "awolverp";
    repo = "cachebox";
    tag = "v${finalAttrs.version}";
    hash = "sha256-kUrBegGA5z4WvaCoJ83jGxuHUWB8ZP1Z9SKi4rK0uoc=";
  };

  cargoDeps = final.rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) src;
    hash = "sha256-JNo0Qagoh1PZNh18xZzF0NWg1l7l/RDu/Bw10jMdFaw=";
  };

  # cargoSetupHook runs on the build host; the cross one cross-builds diffutils to
  # wasm, which pulls gmp, and gmp does not cross to wasix.
  nativeBuildInputs = [
    final.pkgsBuildHost.rustPlatform.cargoSetupHook
    final.rustPlatform.maturinBuildHook
  ];
})
