# h5py for wasix. setup_configure.py ctypes-loads libhdf5 on the BUILD host to
# read the version and feature flags, which the static wasm HDF5 cannot serve.
# That static HDF5 also needs zlib and libaec's sz/aec named on the link, which
# upstream gets through libhdf5.so.
{
  exposeExtendedPackage,
  packages,
  pkgs,
}: let
  crossNumpyInc = packages.sameProfile.numpy.crossInclude;
in
  exposeExtendedPackage {
    env.HDF5_VERSION = pkgs.hdf5.version;
    env.H5PY_ROS3 = "0";
    env.H5PY_DIRECT_VFD = "0";
    buildInputs = [pkgs.zlib pkgs.libaec];
    passthru.wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook];
    # nixpkgs' `cd $out` targets the installed tree. The run-only check has a
    # fresh $out, so resolve the wheel being tested from the guest PYTHONPATH.
    preCheck = _: ''
      export HDF5_USE_FILE_LOCKING=FALSE
      _site=$(echo "$PYTHONPATH" | tr ':' '\n' | grep -m1 -- '-h5py-.*site-packages$')
      cd "$_site"
    '';
    # This HDF5 is built without MPI; nixpkgs' pytest-mpi normally skips it.
    disabledTests = ["TestMPI"];
    # Each extension statically embeds HDF5. Calls and error translation land
    # in distinct HDF5 states; see WASIX-TODO.md.
    pytestFlags = [
      "--deselect=h5py/tests/test_attrs.py::TestAccess::test_access_exc"
      "--deselect=h5py/tests/test_attrs.py::TestAccess::test_get_id"
      "--deselect=h5py/tests/test_attrs.py::TestDelete::test_delete_exc"
      "--deselect=h5py/tests/test_attrs_data.py::TestWriteException::test_write"
      "--deselect=h5py/tests/test_dataset.py::TestCreateRequire::test_type_conflict"
      "--deselect=h5py/tests/test_dataset.py::TestCreateFillvalue::test_exc"
      "--deselect=h5py/tests/test_dataset.py::TestCreateGzip::test_gzip_exc"
      "--deselect=h5py/tests/test_dataset.py::TestCreateCompressionNumber::test_compression_number_invalid"
      "--deselect=h5py/tests/test_dataset.py::test_filter_properties"
      "--deselect=h5py/tests/test_dtype.py::TestDateTime::test_datetime"
      "--deselect=h5py/tests/test_dtype.py::TestDateTime::test_timedelta"
      "--deselect=h5py/tests/test_errors.py"
      "--deselect=h5py/tests/test_file.py::TestFileOpen::test_append"
      "--deselect=h5py/tests/test_file.py::TestFileOpen::test_append_permissions"
      "--deselect=h5py/tests/test_file.py::TestFileOpen::test_create"
      "--deselect=h5py/tests/test_file.py::TestFileOpen::test_create_exclusive"
      "--deselect=h5py/tests/test_file.py::TestFileOpen::test_default"
      "--deselect=h5py/tests/test_file.py::TestFileOpen::test_nonexistent_file"
      "--deselect=h5py/tests/test_file.py::TestFileOpen::test_readonly"
      "--deselect=h5py/tests/test_file.py::TestPageBuffering::test_only_with_page_strategy"
      "--deselect=h5py/tests/test_file.py::TestDrivers::test_core"
      "--deselect=h5py/tests/test_file.py::TestDrivers::test_readonly"
      "--deselect=h5py/tests/test_file.py::TestDrivers::test_sec2"
      "--deselect=h5py/tests/test_file.py::TestDrivers::test_stdio"
      "--deselect=h5py/tests/test_file.py::TestUserblock::test_power_of_two"
      "--deselect=h5py/tests/test_file.py::TestUnicode::test_nonexistent_file_unicode"
      "--deselect=h5py/tests/test_file.py::TestClose::test_closed_file"
      "--deselect=h5py/tests/test_file.py::TestPathlibSupport::test_pathlib_name_match"
      "--deselect=h5py/tests/test_group.py::TestCreate::test_create_exception"
      "--deselect=h5py/tests/test_group.py::TestDelete::test_nonexisting"
      "--deselect=h5py/tests/test_group.py::TestDelete::test_readonly_delete_exception"
      "--deselect=h5py/tests/test_group.py::TestOpen::test_nonexistent"
      "--deselect=h5py/tests/test_group.py::TestPy3Dict::test_items"
      "--deselect=h5py/tests/test_group.py::TestPy3Dict::test_values"
      "--deselect=h5py/tests/test_group.py::TestAdditionalMappingFuncs::test_pop_default"
      "--deselect=h5py/tests/test_group.py::TestAdditionalMappingFuncs::test_pop_raises"
      "--deselect=h5py/tests/test_group.py::TestAdditionalMappingFuncs::test_setdefault_no_default"
      "--deselect=h5py/tests/test_group.py::TestAdditionalMappingFuncs::test_setdefault_with_default"
      "--deselect=h5py/tests/test_group.py::TestGet::test_get_default"
      "--deselect=h5py/tests/test_group.py::TestSoftLinks::test_exc"
      "--deselect=h5py/tests/test_group.py::TestExternalLinks::test_exc"
      "--deselect=h5py/tests/test_group.py::TestExternalLinks::test_exc_missingfile"
      "--deselect=h5py/tests/test_group.py::test_get_elink_mode_arg"
      "--deselect=h5py/tests/test_group.py::test_get_elink_locking_arg"
      "--deselect=h5py/tests/test_group.py::TestMove::test_move_conflict"
      "--deselect=h5py/tests/test_h5p.py::TestPL::test_attr_phase_change"
      "--deselect=h5py/tests/test_vds/test_highlevel_vds.py::SlicingTestCase::test_mismatched_selections"
    ];
    # dtype.elsize reads 0 against the build python's numpy headers; NPY_2_0 gets
    # the version-independent PyDataType_ELSIZE accessor.
    postPatch = ''
      substituteInPlace setup_build.py \
        --replace-fail "numpy.get_include()" "'${crossNumpyInc}'" \
        --replace-fail "NPY_1_21_API_VERSION" "NPY_2_0_API_VERSION" \
        --replace-fail "'libraries'      : ['hdf5', 'hdf5_hl']," "'libraries'      : ['hdf5', 'hdf5_hl', 'z', 'sz', 'aec'],"
    '';
  }
