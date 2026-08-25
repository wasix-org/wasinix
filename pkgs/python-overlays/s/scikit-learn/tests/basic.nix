# scikit-learn under wasmer: import it and fit models offline, exercising the
# numpy/scipy scientific stack and confirming the cross-built OpenMP runtime
# (toolchain.openmp / libomp) is live inside sklearn.
#
# OMP_NUM_THREADS is set first: without it, joblib disables multiprocessing
# when WASIX reports ENOTSUP for its semaphore probe, so sklearn caps OpenMP at
# one thread. With it set, sklearn returns omp_get_max_threads().
#
# Two BLAS paths are exercised. LinearRegression's LAPACK lstsq goes through
# scipy's f2py wrappers, which pass the Fortran hidden CHARACTER-length args.
# KMeans reaches flang's dgemm_ through scipy's cython_blas; that wrapper omitted
# the hidden lengths, so wasm's strict call_indirect turned a latent ABI mismatch
# (harmless on x86) into a signature_mismatch trap. scipy.nix's
# scipy-cython-blas-fortran-charlen.patch regenerates cython_blas/cython_lapack
# to pass those lengths, so the gemm path runs. The direct _test_dgemm call below
# is the tightest regression check on that patch.
{
  wheel,
  harnesses,
  ...
}: {
  fit = harnesses.python {
    name = "scikit-learn-fit";
    inherit wheel;
    script = ''
      import os
      os.environ["OMP_NUM_THREADS"] = "2"

      import numpy as np
      from sklearn.linear_model import LinearRegression
      from sklearn.cluster import KMeans
      from sklearn.utils._openmp_helpers import (
          _openmp_parallelism_enabled,
          _openmp_effective_n_threads,
      )

      # Tightest check on scipy-cython-blas-fortran-charlen.patch: call the
      # reference dgemm_ directly through scipy's cython_blas wrapper. Before the
      # patch this trapped (signature_mismatch:dgemm_) under wasm.
      from scipy.linalg.cython_blas import _test_dgemm
      a = np.array([[1.0, 2.0], [3.0, 4.0]], order="F")
      b = np.array([[5.0, 6.0], [7.0, 8.0]], order="F")
      c = np.zeros((2, 2), order="F")
      _test_dgemm(1.0, a, b, 0.0, c)
      assert np.allclose(c, a @ b), c

      # LinearRegression recovers y = 2x + 1 (LAPACK lstsq via scipy f2py wrappers).
      X = np.arange(10, dtype=float).reshape(-1, 1)
      y = 2.0 * X.ravel() + 1.0
      lr = LinearRegression().fit(X, y)
      assert abs(lr.coef_[0] - 2.0) < 1e-6, lr.coef_
      assert abs(lr.intercept_ - 1.0) < 1e-6, lr.intercept_
      assert abs(lr.predict([[10.0]])[0] - 21.0) < 1e-6

      # KMeans reaches BLAS gemm through cython_blas: two well-separated blobs
      # must split into two clusters. This is the estimator that trapped before
      # the charlen patch.
      pts = np.array([[0.0, 0.0], [0.1, 0.1], [10.0, 10.0], [10.1, 9.9]])
      km = KMeans(n_clusters=2, n_init=1, random_state=0).fit(pts)
      labels = km.labels_
      assert labels[0] == labels[1] and labels[2] == labels[3]
      assert labels[0] != labels[2], labels

      # The cross-built libomp is compiled into sklearn and live: parallelism is
      # enabled at build time and omp_get_max_threads() honours OMP_NUM_THREADS.
      assert _openmp_parallelism_enabled() is True
      assert _openmp_effective_n_threads() == 2, _openmp_effective_n_threads()
      print("openmp enabled:", _openmp_parallelism_enabled(),
            "n_threads:", _openmp_effective_n_threads(),
            "kmeans+dgemm ok")
    '';
  };

  # Pin both sides of the OMP_NUM_THREADS behavior described above.
  openmp-threads = harnesses.python {
    name = "scikit-learn-openmp-threads";
    inherit wheel;
    script = ''
      import os
      from sklearn.utils._openmp_helpers import _openmp_effective_n_threads

      assert "OMP_NUM_THREADS" not in os.environ
      assert _openmp_effective_n_threads() == 1, _openmp_effective_n_threads()
    '';
  };
}
