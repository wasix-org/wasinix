# ansible is an optional Dynaconf integration. nixpkgs enables it by default,
# but ansible's Paramiko closure requires a WASIX Bash at runtime.
{
  exposePackage,
  package,
  lib,
}:
exposePackage (
  package.overridePythonAttrs (old: {
    dependencies = lib.filter (dep: (lib.getName dep) != "ansible-core") old.dependencies;
  })
)
