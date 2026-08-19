# soundfile for wasix. It cffi-dlopens libsndfile at import, so the library is
# bundled into the wheel rather than referenced by a store path a bare wasix target
# lacks. Upstream already ships that machinery through _soundfile_data; only its
# runtime platform switch needs a wasix branch, sys.platform being unknown to it.
{
  final,
  lib,
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  # setup.py derives the bundled libname from these; keep the runtime name below in step.
  # Only `linux` packages _soundfile_data at all, and it also picks the wheel's
  # platform tag, which the postPatch below corrects.
  env = {
    PYSOUNDFILE_PLATFORM = "linux";
    PYSOUNDFILE_ARCHITECTURE = "wasm32";
  };
  # _soundfile_data must be a real package, not a namespace one: the loader reads
  # its __file__. `_:` replaces nixpkgs' postPatch, which bakes a store path.
  postPatch = _: ''
    install -Dm644 ${lib.getLib final.libsndfile}/lib/libsndfile.so _soundfile_data/libsndfile_wasm32.so
    touch _soundfile_data/__init__.py
    substituteInPlace soundfile.py \
      --replace-fail "raise OSError('no packaged library for this platform')" \
                     "_packaged_libname = 'libsndfile_wasm32.so'"
    substituteInPlace setup.py \
      --replace-fail "oses = 'manylinux_2_28_{}'.format(pep600_architecture)" \
                     "oses = 'wasix_wasm32'"
  '';
  pytestFlags =
    [
      "--deselect=tests/test_soundfile.py::test_if_open_with_mode_w_truncates"
      "--deselect=tests/test_soundfile.py::test_write_flush_should_write_to_disk[obj]"
    ]
    ++ lib.optionals (lib.versionOlder pyfinal.python.version "3.14") [
      # This file-object write is not visible when reopened by path on Python 3.13.
      "--deselect=tests/test_soundfile.py::test_file_attributes_should_save_to_disk[obj]"
    ];
}
pyprev.soundfile
