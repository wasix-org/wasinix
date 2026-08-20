# scipy under wasmer: exercise the hand-written C/C++ BLAS/LAPACK glue whose
# Fortran calls omitted flang's hidden CHARACTER-length args and so trapped under
# wasm's strict call_indirect (signature_mismatch). scipy-hand-c-blas-fortran-
# charlen.patch asm-redirects those calls through length-appending wrappers; this
# runs the fixed APIs offline and checks the numbers, not just that they import:
#
#  - optimize L-BFGS-B / SLSQP  -> _lbfgsb / _slsqplib   (blaslapack_declarations.h)
#  - integrate odeint / solve_ivp LSODA -> _odepack / _lsoda  (blaslapack_declarations.h)
#  - linalg expm / sqrtm        -> _internal_matfuncs      (_common_array_utils.h)
#  - linalg svd/lu/qr/cholesky/eig -> _batched_linalg       (_common_array_utils.hh)
#  - sparse svds(solver=propack) -> _propack               (blaslapack_declarations.h)
{
  wheel,
  runPython,
  ...
}: {
  blas-lapack = runPython {
    name = "scipy-blas-lapack";
    inherit wheel;
    script = ''
      import numpy as np

      # optimize: L-BFGS-B and SLSQP (_lbfgsb, _slsqplib). Both nail a convex
      # quadratic; L-BFGS-B also drives Rosenbrock to its minimum.
      from scipy.optimize import minimize, rosen
      quad = lambda x: (x[0] - 3.0) ** 2 + (x[1] + 1.0) ** 2
      for method in ("L-BFGS-B", "SLSQP"):
          r = minimize(quad, [0.0, 0.0], method=method)
          assert r.success, (method, r.message)
          assert np.allclose(r.x, [3.0, -1.0], atol=1e-4), (method, r.x)
      rb = minimize(rosen, [-1.2, 1.0], method="L-BFGS-B")
      assert rb.fun < 1e-6, rb.fun

      # integrate: dy/dt = -y, y0 = 1  =>  y(1) = e^-1, via odeint and LSODA.
      from scipy.integrate import odeint, solve_ivp
      y1 = odeint(lambda y, t: -y, 1.0, [0.0, 1.0])[-1, 0]
      assert abs(y1 - np.exp(-1.0)) < 1e-5, y1
      sol = solve_ivp(lambda t, y: -y, (0.0, 1.0), [1.0], method="LSODA",
                      rtol=1e-9, atol=1e-11)
      assert sol.success, sol.message
      assert abs(sol.y[0, -1] - np.exp(-1.0)) < 1e-5, sol.y[0, -1]

      # linalg matrix functions: expm (dgemm/dgemv) and sqrtm (dgees/dtrsyl/dgemm).
      from scipy.linalg import expm, sqrtm
      assert np.allclose(expm(np.zeros((2, 2))), np.eye(2)), "expm(0) != I"
      assert np.allclose(expm(np.diag([0.5, -1.0])),
                         np.diag([np.exp(0.5), np.exp(-1.0)])), "expm(diag)"
      assert np.allclose(expm(np.array([[0.0, 1.0], [0.0, 0.0]])),
                         np.array([[1.0, 1.0], [0.0, 1.0]])), "expm(nilpotent)"
      A = np.array([[4.0, 1.0], [1.0, 3.0]])
      S = sqrtm(A)
      assert np.allclose(S @ S, A, atol=1e-8), S @ S

      # linalg decompositions routed through _batched_linalg.
      from scipy.linalg import svd, lu, qr, cholesky, eig
      M = np.array([[4.0, 2.0, 0.0], [2.0, 5.0, 1.0], [0.0, 1.0, 3.0]])  # SPD
      U, s, Vh = svd(M)
      assert np.allclose((U * s) @ Vh, M, atol=1e-8), "svd reconstruct"
      P, L, Uf = lu(M)
      assert np.allclose(P @ L @ Uf, M, atol=1e-8), "lu reconstruct"
      Q, R = qr(M)
      assert np.allclose(Q @ R, M, atol=1e-8), "qr reconstruct"
      assert np.allclose(Q.T @ Q, np.eye(3), atol=1e-8), "qr orthonormal"
      Lc = cholesky(M, lower=True)
      assert np.allclose(Lc @ Lc.T, M, atol=1e-8), "cholesky reconstruct"
      w = np.sort(eig(np.diag([1.0, 2.0, 3.0]), right=False).real)
      assert np.allclose(w, [1.0, 2.0, 3.0], atol=1e-8), w

      # sparse: PROPACK svds top singular value matches dense reference.
      from scipy.sparse.linalg import svds
      B = np.array([[1.0, 0.0, 0.0], [0.0, 2.0, 0.0],
                    [0.0, 0.0, 3.0], [1.0, 1.0, 1.0]])
      _, sv, _ = svds(B, k=1, solver="propack", random_state=0)
      top = np.linalg.svd(B, compute_uv=False)[0]
      assert abs(sv[0] - top) < 1e-6, (sv[0], top)

      print("scipy ok: L-BFGS-B SLSQP odeint LSODA expm sqrtm svd lu qr "
            "cholesky eig svds(propack)")
    '';
  };

  # A COMPLEX-returning Fortran function has no one C ABI, so scipy wraps
  # cdotu/cdotc/zdotu/zdotc. Off Accelerate/MKL it picks wrap_dummy_g77_abi.c,
  # which declares them as returning a C99 complex: the clang caller and the
  # flang callee then have to agree on the wasm32 complex return lowering
  # (flang-wasm32-target.patch). Nothing at link time checks that they do.
  complex-blas = runPython {
    name = "scipy-complex-blas";
    inherit wheel;
    script = ''
      import numpy as np
      from scipy.linalg import blas

      u = np.array([1 + 2j, 3 - 1j], dtype=np.complex64)
      v = np.array([4 - 1j, 2 + 3j], dtype=np.complex64)
      assert np.allclose(blas.cdotu(u, v), 15 + 14j), blas.cdotu(u, v)
      assert np.allclose(blas.cdotc(u, v), 5 + 2j), blas.cdotc(u, v)

      U, V = u.astype(np.complex128), v.astype(np.complex128)
      assert np.allclose(blas.zdotu(U, V), 15 + 14j), blas.zdotu(U, V)
      assert np.allclose(blas.zdotc(U, V), 5 + 2j), blas.zdotc(U, V)

      print("scipy complex blas ok: cdotu cdotc zdotu zdotc")
    '';
  };

  # -D_without-fortran=true is meant to cost scipy.odr and nothing else. Pin both
  # halves so a bump that moves Fortran into another subpackage, or that adds a
  # subpackage, fails here instead of silently shipping a hole.
  submodules = runPython {
    name = "scipy-submodules";
    inherit wheel;
    script = ''
      import importlib
      import scipy

      # scipy.__init__ drops 'odr' from this list when the odr package is absent.
      expected = {
          "cluster", "constants", "datasets", "differentiate", "fft", "fftpack",
          "integrate", "interpolate", "io", "linalg", "ndimage", "optimize",
          "signal", "sparse", "spatial", "special", "stats",
      }
      got = set(scipy.submodules)
      assert got == expected, sorted(got ^ expected)

      for name in sorted(expected):
          importlib.import_module("scipy." + name)

      try:
          importlib.import_module("scipy.odr")
      except ImportError:
          pass
      else:
          raise AssertionError("scipy.odr imports; _without-fortran no longer drops it")

      print("scipy submodules ok:", len(expected), "imported, odr absent")
    '';
  };
}
