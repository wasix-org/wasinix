# murmurhash for wasix. Same host-include leak as cymem.nix, but the entry sits in
# a multi-line list, so drop just that element (matching no newline).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'get_path("include"),' ""
  '';
}
pyprev.murmurhash
