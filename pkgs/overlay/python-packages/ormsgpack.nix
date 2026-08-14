# ormsgpack for wasix. maturin/pyo3 wheel (fast msgpack; langgraph serde core).
# Its Cargo.toml bakes pyo3's extension-module into the default features, so only
# the cross sysconfig is needed to build. But at import it traps: CPython 3.13 added
# a 6th `with_exceptions` param to `_PyLong_AsByteArray`, and pyo3-ffi 0.27 still
# declares the pre-3.13 5-arg form. On native platforms the arg-count mismatch is
# latent UB; wasm import type-checking is strict, so the 5-arg import doesn't match
# libpython's 6-arg export. ormsgpack calls it once (uuid serialization); rebind it
# to the correct 6-arg signature (pyo3-ffi's unused 5-arg decl is then dead).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    cat >> src/serialize/uuid.rs <<'RS'

    extern "C" {
        #[link_name = "_PyLong_AsByteArray"]
        fn wasix_pylong_as_byte_array(
            v: *mut pyo3::ffi::PyLongObject,
            bytes: *mut u8,
            n: usize,
            little_endian: i32,
            is_signed: i32,
            with_exceptions: i32,
        ) -> i32;
    }
    RS
    substituteInPlace src/serialize/uuid.rs \
      --replace-fail 'pyo3::ffi::_PyLong_AsByteArray(' 'wasix_pylong_as_byte_array(' \
      --replace-fail '0, // is_signed' '0, /* is_signed */ 1,'
  '';
  # both import pydantic, whose pydantic_core extension does not load in the
  # guest; the import error at collection aborts the entire run
  disabledTestPaths = ["tests/test_pydantic.py" "tests/test_types.py"];
}
pyprev.ormsgpack
