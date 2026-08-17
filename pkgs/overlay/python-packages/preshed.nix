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
    pytestFlagsArray+=("$PWD/preshed/tests")
    cd $out
  '';
}
pyprev.preshed
