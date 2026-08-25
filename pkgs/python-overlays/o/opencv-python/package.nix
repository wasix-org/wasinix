# The distribution names PyPI serves cv2 under. nixpkgs models opencv-python as a
# metapackage requiring its `opencv` module, but no `opencv` distribution exists
# on PyPI, so that wheel carries no cv2 and nothing can ever satisfy it; a
# registry overlaying PyPI has to ship the payload under the real names. Both
# pack the same cv2: this build has no windowing toolkit at all (WITH_GTK and
# WITH_QT are off in wasix/opencv4), which is what headless means, so
# they differ only in the name pip matches, as upstream's two wheels do.
{
  packages,
  pkgs,
}: let
  names = ["opencv-python" "opencv-python-headless"];

  module = packages.sameProfile.opencv4;
  inherit (module) version;
  py = packages.sameProfile.python;
  # The tag the cross interpreter stamps on its own wheels
  # (_PYTHON_HOST_PLATFORM=wasix-wasm32, wasix/python3); re-derive
  # from a built wheel's filename if the target triple drifts.
  cpTag = "cp${builtins.replaceStrings ["."] [""] py.pythonVersion}";
  wheelTag = "${cpTag}-${cpTag}-wasix_wasm32";

  # cv2 as it is installed, repacked under `pname` with a correct tag: the
  # module ships a py3-none-any dist-info despite carrying a compiled .so.
  distOf = pname: let
    escaped = builtins.replaceStrings ["-"] ["_"] pname;
  in
    pkgs.runCommand "${pname}-${version}-dist" {
      nativeBuildInputs = [pkgs.buildPackages.python3.pkgs.wheel];
    } ''
      stage=$TMPDIR/stage
      info="$stage/${escaped}-${version}.dist-info"
      mkdir -p "$info"
      cp -r ${module}/${py.sitePackages}/cv2 "$stage/cv2"
      chmod -R u+w "$stage"

      cat > "$info/METADATA" <<EOF
      Metadata-Version: 2.1
      Name: ${pname}
      Version: ${version}
      Summary: Wrapper package for OpenCV python bindings.
      Requires-Dist: numpy
      EOF

      cat > "$info/WHEEL" <<EOF
      Wheel-Version: 1.0
      Generator: wasinix
      Root-Is-Purelib: false
      Tag: ${wheelTag}
      EOF

      mkdir -p "$out/dist"
      wheel pack --dest-dir "$out/dist" "$stage"
    '';

  mkPackage = pname:
    packages.sameProfile.buildPythonPackage {
      inherit pname version;
      format = "wheel";

      src = distOf pname;
      dontUseWheelUnpack = true;

      dependencies = [packages.sameProfile.numpy];

      pythonImportsCheck = ["cv2"];
      passthru.wasinix.checks.captured.install = false;
    };
in
  builtins.listToAttrs (map (pname: {
      name = pname;
      value = mkPackage pname;
    })
    names)
