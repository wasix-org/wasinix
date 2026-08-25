# PyArrow under wasmer: exercise the optional native modules enabled in arrow-cpp,
# not only the base/parquet imports.
{
  wheel,
  harnesses,
  ...
}: {
  dataset = harnesses.python {
    name = "pyarrow-dataset";
    inherit wheel;
    script = ''
      import pyarrow as pa
      import pyarrow.compute as pc
      import pyarrow.dataset as ds
      import pyarrow.parquet.encryption as encryption

      table = pa.table({"x": [1, 2, 3], "name": ["a", "b", "c"]})
      result = ds.dataset(table).to_table(filter=ds.field("x") > 1)
      assert result["x"].to_pylist() == [2, 3], result
      assert pc.sum(result["x"]).as_py() == 5
      assert encryption.CryptoFactory is not None
    '';
  };
}
