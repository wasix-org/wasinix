# Constructors for passthru.wasmer.dependencies entries. Requirements are
# derived from the published webc version, which may differ from package.version.
{lib}: let
  inherit (import ./ident.nix {inherit lib;}) webcIdent;
  withVersion = requirement: package: {
    inherit package;
    version = requirement (webcIdent package).version;
  };
in {
  any = withVersion (_: "*");
  exact = withVersion (version: "=${version}");
  compatibleMajor = withVersion (version: "^${version}");
  compatibleMinor = withVersion (version: "~${version}");

  # A bare derivation retains the original dependency behaviour: its published
  # version is a semver-compatible requirement.
  normalize = dependency:
    if lib.isDerivation dependency
    then withVersion (version: version) dependency
    else if
      dependency ? package
      && lib.isDerivation dependency.package
      && dependency ? version
      && builtins.isString dependency.version
    then dependency
    else throw "passthru.wasmer.dependencies entries must be derivations or { package = <derivation>; version = <requirement>; }";
}
