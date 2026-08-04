# srsly for wasix. Same host-include leak as cymem.nix; the source-relative includes stay.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'include_dirs = [get_path("include"), ".", "srsly"]' 'include_dirs = [".", "srsly"]'
  '';
}
pyprev.srsly
