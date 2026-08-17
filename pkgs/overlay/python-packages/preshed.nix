# preshed for wasix. Same host-include leak as cymem.nix.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'include_dirs = [get_path("include")]' 'include_dirs = []'
  '';
  preCheck = ''
    _source_tests="$PWD/preshed/tests"
    _site=$(echo "$PYTHONPATH" | tr ':' '\n' | grep -m1 -- '-preshed-.*site-packages$')
    cp -r "$_site/preshed" "$NIX_BUILD_TOP/preshed"
    chmod -R u+w "$NIX_BUILD_TOP/preshed"
    cp -r "$_source_tests" "$NIX_BUILD_TOP/preshed/tests"
    export PYTHONPATH="$NIX_BUILD_TOP:$PYTHONPATH"
    pytestFlagsArray=("$NIX_BUILD_TOP/preshed/tests")
    cd "$NIX_BUILD_TOP"
  '';
}
pyprev.preshed
