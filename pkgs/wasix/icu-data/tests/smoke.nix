# End-to-end smoke test per icu major: a C program statically linking icuNN,
# packaged as a webc depending on the icu-dataNN webc, must format a date via
# the archive at the baked-in /share/icu/<ver> default (no ICU_DATA set). The
# no-dep variant proves the check really depends on the mounted data.
{
  harnesses,
  packages,
  ...
}: let
  versions = import ../../icu/versions.nix;

  prog = v: deps:
    packages.sameProfile.stdenv.mkDerivation {
      pname = "icu-smoke${v}";
      version = "1.0.0";
      dontUnpack = true;
      buildInputs = [packages.sameProfile."icu${v}"];
      buildPhase = ''
        $CXX ${./smoke.cc} -o icu-smoke.wasm -licui18n -licuuc -licudata
      '';
      installPhase = ''
        install -Dm755 icu-smoke.wasm -t "$out/bin"
      '';
      passthru.wasmer = {
        name = "icu-smoke${v}";
        dependencies = deps;
      };
    };

  smoke = v:
    harnesses.hostShell {
      name = "icu-data${v}-smoke";
      wasixCommands = [
        (harnesses.packageCommand {package = prog v [packages.sameProfile."icu-data${v}"];})
      ];
      script = ''
        out=$(icu-smoke)
        echo "$out"
        [ "$out" = "1. Januar 1970" ]
      '';
    };
in
  builtins.listToAttrs (map (v: {
      name = "smoke${v}";
      value = smoke v;
    })
    versions)
  // {
    # Same program without the webc dependency: the archive is absent, so the
    # data lookup at /share/icu/<ver> must fail.
    no-dep = let
      defaultMajor = packages.sameProfile.lib.versions.major packages.sameProfile.icu.version;
    in
      harnesses.hostShell {
        name = "icu-data-no-dep";
        expectFail = "no icu-data dependency, the data archive is not mounted";
        wasixCommands = [
          (harnesses.packageCommand {package = prog defaultMajor [];})
        ];
        script = "icu-smoke";
      };
  }
