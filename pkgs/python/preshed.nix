# preshed for wasix. Same host-include leak as cymem.nix.
{
  exposeExtendedPackage,
  pkgs,
}:
exposeExtendedPackage {
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'include_dirs = [get_path("include")]' 'include_dirs = []'
  '';
  preCheck = ''
    _source_tests="$PWD/preshed/tests"
    _site=
    for _path in ''${PYTHONPATH//:/ }; do
      case "$_path" in *-preshed-*/lib/python*/site-packages) _site="$_path"; break ;; esac
    done
    [ -n "$_site" ] || exit 1
    ${pkgs.lib.getExe' pkgs.buildPackages.coreutils "cp"} -r "$_site/preshed" "$NIX_BUILD_TOP/preshed"
    ${pkgs.lib.getExe' pkgs.buildPackages.coreutils "chmod"} -R u+w "$NIX_BUILD_TOP/preshed"
    ${pkgs.lib.getExe' pkgs.buildPackages.coreutils "cp"} -r "$_source_tests/." "$NIX_BUILD_TOP/preshed/tests/"
    export PYTHONPATH="$NIX_BUILD_TOP:$PYTHONPATH"
    pytestFlagsArray=("$NIX_BUILD_TOP/preshed/tests")
    cd "$NIX_BUILD_TOP"
  '';
}
