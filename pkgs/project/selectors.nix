{
  lib,
  project,
}: let
  catalog = project.catalog.entries;
  jobsForSubjects = group: subjects: let
    catalogSubjects = lib.unique (lib.concatMap (entry: entry.packageSubjects or [entry.address]) (builtins.attrValues catalog));
    unknown = lib.subtractLists catalogSubjects subjects;
  in
    lib.throwIf (unknown != [])
    "CI selector group '${group}' names unknown package subject(s): ${lib.concatStringsSep ", " unknown}"
    (map (entry: entry.address) (lib.filter (entry:
      lib.intersectLists (entry.packageSubjects or [entry.address]) subjects != [])
    (builtins.attrValues catalog)));
  nativeSubjects = names: map (name: "packages.native.${name}") names;
  pandocSubjects = map (entry: entry.address) (lib.filter (entry:
    entry.kind
    == "package"
    && entry.scope == "wasix"
    && entry.name == "pandoc"
    && entry.instance.kind == "current")
  (builtins.attrValues catalog));
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
    "wasi-ghc"
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
    jobs = jobsForSubjects "toolchain" (nativeSubjects toolchainNames);
  };
  cc = {
    jobs = jobsForSubjects "cc" (nativeSubjects ccNames);
  };
  rust = {
    jobs = jobsForSubjects "rust" (nativeSubjects rustNames);
  };
  haskell = {
    jobs = jobsForSubjects "haskell" (["packages.native.wasi-ghc"] ++ pandocSubjects);
  };
  emulated = {
    jobs = map (entry: entry.address) (lib.filter (entry: entry.testName or null == "captured") (builtins.attrValues catalog));
  };
}
