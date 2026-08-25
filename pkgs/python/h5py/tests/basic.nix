# h5py under wasmer: exercise real HDF5 file I/O, not just `import h5py`. Writes
# a file (dataset + attribute + group + a gzip-compressed dataset), closes it,
# reopens read-only, and asserts the array round-trips and the metadata is
# present. This is the whole point of the port: it drives the HDF5 sec2 VFD
# (pread/pwrite/ftruncate), the type-detection init (H5open), and the zlib
# deflate filter.
#
# HDF5_USE_FILE_LOCKING=FALSE: Wasmer does not implement cross-process advisory
# record locks, so wasix-libc returns ENOSYS for F_*LK. Disable HDF5 locking for
# this isolated test instead of claiming synchronization it does not have.
{
  wheel,
  harnesses,
  ...
}: {
  read-write = harnesses.python {
    name = "h5py-read-write";
    inherit wheel;
    script = ''
      import os
      os.environ["HDF5_USE_FILE_LOCKING"] = "FALSE"

      import numpy as np
      import h5py

      # Write to the mapped, writable HOME (the harness maps /home to a host dir).
      workdir = os.environ.get("HOME", "/tmp")
      path = os.path.join(workdir, "test.h5")

      data = np.arange(24, dtype="f8").reshape(4, 6)
      comp = (np.arange(1000, dtype="i4") % 7)

      with h5py.File(path, "w") as f:
          f.create_dataset("plain", data=data)
          f.create_dataset("packed", data=comp, compression="gzip",
                           compression_opts=9)
          f.attrs["title"] = "wasix roundtrip"
          f.attrs["n"] = 42
          g = f.create_group("grp")
          g.create_dataset("child", data=np.array([1.5, 2.5, 3.5]))

      assert os.path.getsize(path) > 0, "empty HDF5 file"

      with h5py.File(path, "r") as f:
          got = f["plain"][()]
          assert np.array_equal(got, data), got
          assert got.dtype == data.dtype, got.dtype

          # gzip filter must have linked (zlib) and round-trip losslessly.
          pk = f["packed"]
          assert pk.compression == "gzip", pk.compression
          assert np.array_equal(pk[()], comp), "gzip roundtrip mismatch"

          assert f.attrs["title"] == "wasix roundtrip", f.attrs["title"]
          assert int(f.attrs["n"]) == 42, f.attrs["n"]

          assert "grp" in f, list(f.keys())
          assert np.array_equal(f["grp/child"][()], [1.5, 2.5, 3.5])

      print("h5py ok:", h5py.version.hdf5_version,
            "wrote+read dataset/attr/group + gzip filter")
    '';
  };
}
