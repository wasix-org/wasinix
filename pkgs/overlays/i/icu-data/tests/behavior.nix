# End-to-end behavior check for one ICU data package: a C program statically
# linking the matching ICU major must load its archive from the WebC mount.
{
  commands,
  entry,
  harnesses,
  packageForEntry,
  packages,
  ...
}: let
  package = packageForEntry packages entry;
  major = packages.sameProfile.lib.versions.major package.version;
  prog = deps:
    packages.sameProfile.stdenv.mkDerivation {
      pname = "icu-behavior${major}";
      version = "1.0.0";
      dontUnpack = true;
      buildInputs = [packages.sameProfile."icu${major}"];
      buildPhase = ''
        $CXX ${./behavior.cc} -o icu-behavior.wasm -licui18n -licuuc -licudata
      '';
      installPhase = ''
        install -Dm755 icu-behavior.wasm -t "$out/bin"
      '';
      passthru.wasmer = {
        name = "icu-behavior${major}";
        entrypoint = "icu-behavior";
        dependencies = deps;
      };
      meta.mainProgram = "icu-behavior";
    };
in {
  behavior = harnesses.wasixShell {
    name = "icu-data${major}-behavior";
    shell = commands.bash;
    commands = [
      (harnesses.packageCommand {
        package = prog [package];
        name = "icu-behavior";
      })
    ];
    script = ''
      out=$(icu-behavior)
      echo "$out"
      [ "$out" = "1. Januar 1970" ]
    '';
  };

  # The same program without the WebC dependency proves the archive mount is
  # what makes the positive check pass.
  no-dep = harnesses.wasixShell {
    name = "icu-data${major}-no-dep";
    expectFail = "no icu-data dependency, the data archive is not mounted";
    shell = commands.bash;
    commands = [
      (harnesses.packageCommand {
        package = prog [];
        name = "icu-behavior";
      })
    ];
    script = "icu-behavior";
  };
}
