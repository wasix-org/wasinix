# The CLI suite spawns `python -m idna`; the one case that pipes data into the
# child's stdin gets exit 2 from the guest, the rest passes.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.idna {
  disabledTests = ["test_python_dash_m_idna_reads_piped_stdin"];
}
