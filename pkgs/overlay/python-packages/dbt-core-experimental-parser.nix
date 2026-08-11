# The distribution python dbt-core 1.12 requires. Upstream packs the Fusion
# engine binary under .data/scripts with no python code at all, so this packs
# ours the same way; the wheel is tagged for the platform but not the
# interpreter, exactly as upstream's py3-none-manylinux artifact is.
{
  pyfinal,
  final,
  preferredProfilePackages,
  ...
}: let
  engine = preferredProfilePackages.dbt-sa-cli;
  # PEP 440 spelling of the engine's 2.0.0-alpha.5, which is what dbt-core's
  # `>=2.0.0a4` resolves against.
  version = "2.0.0a5";
  pname = "dbt-core-experimental-parser";
  escaped = builtins.replaceStrings ["-"] ["_"] pname;

  dist =
    final.runCommand "${pname}-${version}-dist" {
      nativeBuildInputs = [final.buildPackages.python3.pkgs.wheel];
    } ''
      stage=$TMPDIR/stage
      info="$stage/${escaped}-${version}.dist-info"
      scripts="$stage/${escaped}-${version}.data/scripts"
      mkdir -p "$info" "$scripts"
      install -Dm755 ${engine}/bin/dbt-sa-cli.wasm "$scripts/${pname}"

      cat > "$info/METADATA" <<EOF
      Metadata-Version: 2.1
      Name: ${pname}
      Version: ${version}
      Summary: Build analytics the way engineers build applications
      License: Apache-2.0
      Requires-Python: >=3.9
      EOF

      cat > "$info/WHEEL" <<EOF
      Wheel-Version: 1.0
      Generator: wasinix
      Root-Is-Purelib: false
      Tag: py3-none-wasix_wasm32
      EOF

      mkdir -p "$out/dist"
      wheel pack --dest-dir "$out/dist" "$stage"
    '';
in
  pyfinal.buildPythonPackage {
    inherit pname version;
    format = "wheel";

    src = dist;
    dontUseWheelUnpack = true;

    # no python module to import; the wheel ships one executable
    dontCheckRuntimeDeps = true;
  }
