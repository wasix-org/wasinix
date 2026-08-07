# ansible is an optional Dynaconf integration. nixpkgs enables it by default,
# but ansible's Paramiko closure requires a WASIX Bash at runtime.
{
  lib,
  pyprev,
  ...
}:
pyprev.dynaconf.overridePythonAttrs (old: {
  dependencies = lib.filter (dep: (lib.getName dep) != "ansible-core") old.dependencies;
})
