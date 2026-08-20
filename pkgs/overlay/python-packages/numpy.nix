# numpy for wasix. openblas doesn't cross-build (throws "unsupported system: wasm32-wasi");
# use the bundled reference BLAS (-Dallow-noblas) and drop blas/lapack + gfortran + the site.cfg.
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  # gfortran only compiles the Fortran BLAS wrappers; allow-noblas leaves nothing to compile.
  noFortran = lib.filter (x: !(lib.hasInfix "gfortran" (lib.getName x)));
in
  # wasm build only: the noblas/-fexceptions/no-gfortran variant breaks the native checkPhase.
  lib.fix (self:
    helpers.extendPackage pyprev.numpy (
      helpers.linkInputs (helpers.dropInputsByName ["blas" "lapack"])
      // {
        # Extensions must use the target numpy headers: build-python headers use
        # a 64-bit long and mis-size npy_intp for wasm32.
        passthru.crossInclude = "${self}/lib/${pyprev.python.libPrefix}/site-packages/numpy/_core/include";
        # the wheel-shipped suite in tests/upstream.nix replaces the derived
        # source-tree check (the source numpy/ has no compiled modules)
        passthru.wasinix.checks.captured.install = false;
        nativeBuildInputs = noFortran;
        # numpy < 2.3 vendors meson 1.5, which rejects default_both_libraries
        # (nixpkgs passes it for current numpy; meson knows it from 1.6).
        mesonFlags = old:
          lib.filter (
            f:
              lib.versionAtLeast pyprev.numpy.version "2.3"
              || f != "-Ddefault_both_libraries=static"
          ) (old ++ [(lib.mesonBool "allow-noblas" true)]);
        # lib.const = replace, not concat: drop upstream's site.cfg symlink (dead BLAS paths)
        # and its /bin/true→coreutils test rewrite.
        preBuild = lib.const "";
        postPatch = lib.const (''
            substituteInPlace numpy/meson.build \
              --replace-fail 'py.full_path()' "'python'"

            # ehpic PIC needs wasm-EH, so -fno-exceptions is rejected; keep exceptions on.
            substituteInPlace numpy/_core/meson.build \
              --replace-fail "'-fno-exceptions',  # no exception support" "'-fexceptions',  # wasix ehpic: PIC needs wasm-EH"

            # long-double format is normally found by a run-probe (no exe_wrapper here); wasm32
            # is IEEE binary128 → supply IEEE_QUAD_LE directly.
            substituteInPlace numpy/_core/meson.build \
              --replace-fail "meson.get_external_property('longdouble_format', 'UNKNOWN')" "meson.get_external_property('longdouble_format', 'IEEE_QUAD_LE')"

            substituteInPlace numpy/_core/memmap.py \
              --replace-fail "fid.seek(bytes - 1, 0)" "os.ftruncate(fid.fileno(), bytes)" \
              --replace-fail "fid.write(b'\\0')" "" \
              --replace-fail "fid.flush()" ""
          ''
          # npy_cpu.h < 2.4 only knows wasm under emscripten; clang targeting
          # wasm32-wasi defines __wasm__ (what upstream widened the guard to in 2.4).
          + lib.optionalString (lib.versionOlder pyprev.numpy.version "2.4") ''
            substituteInPlace numpy/_core/include/numpy/npy_cpu.h \
              --replace-fail '#elif defined(__EMSCRIPTEN__)' '#elif defined(__EMSCRIPTEN__) || defined(__wasm__)'
          '');
      }
    ))
