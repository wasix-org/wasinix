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
  # Keep the source tree from shadowing the installed extension modules.
  pytestFlags = ["--import-mode=importlib"];
}
pyprev.preshed
