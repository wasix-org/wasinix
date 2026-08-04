# cymem for wasix. setup.py hand-adds sysconfig.get_path("include"), which resolves
# from the running build interpreter (_PYTHON_SYSCONFIGDATA_NAME redirects
# get_config_var, not get_path) and lands ahead of the target include, so pyport.h
# checks the host SIZEOF_LONG 8 against wasm's LONG_BIT 32 and hard-errors.
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
}
pyprev.cymem
