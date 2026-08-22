{
  lib,
  project,
}: let
  catalog = project.catalog.entries;
  jobsForSubjects = subjects:
    map (entry: entry.address) (lib.filter (entry:
      builtins.elem (entry.packageSubject or entry.address) subjects)
    (builtins.attrValues catalog));
  nativeSubjects = names: map (name: "packages.native.${name}") names;
  pandocSubjects = map (profile: "packages.wasix.${profile}.pandoc") (builtins.attrNames project.packages.wasix);
  toolchainNames = [
    "cargo-wasix"
    "cargo-wasix-unwrapped"
    "wasix-flang"
    "wasix-llvm"
    "wasix-rust"
    "wasix-sysroot"
    "wasix-tinygo"
    "wasixcc"
    "wasixcc-unwrapped"
  ];
  ccNames = [
    "wasix-flang"
    "wasix-llvm"
    "wasix-sysroot"
    "wasix-tinygo"
    "wasixcc"
    "wasixcc-unwrapped"
  ];
  rustNames = ["cargo-wasix" "cargo-wasix-unwrapped" "wasix-rust"];
in {
  toolchain = {
    jobs = jobsForSubjects (nativeSubjects toolchainNames);
  };
  cc = {
    jobs = jobsForSubjects (nativeSubjects ccNames);
  };
  rust = {
    jobs = jobsForSubjects (nativeSubjects rustNames);
  };
  haskell = {
    jobs = jobsForSubjects pandocSubjects;
  };
  emulated = {
    jobs = map (entry: entry.address) (lib.filter (entry: entry.testName or null == "captured") (builtins.attrValues catalog));
  };
}
