# numpy for wasix. openblas doesn't cross-build (throws "unsupported system: wasm32-wasi");
# use the bundled reference BLAS (-Dallow-noblas) and drop blas/lapack + gfortran + the site.cfg.
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
  # gfortran only compiles the Fortran BLAS wrappers; allow-noblas leaves nothing to compile.
  noFortran = lib.filter (x: !(lib.hasInfix "gfortran" (lib.getName x)));
in
  # wasm build only: the noblas/-fexceptions/no-gfortran variant breaks the native checkPhase.
  wheels.onlyOnWasix pyprev.numpy (
    helpers.libTweaks (
      wheels.dropInputsByName ["blas" "lapack"]
      // {
        nativeBuildInputs = noFortran;
        mesonFlags = [(lib.mesonBool "allow-noblas" true)];
        # lib.const = replace, not concat: drop upstream's site.cfg symlink (dead BLAS paths)
        # and its /bin/true→coreutils test rewrite.
        preBuild = lib.const "";
        postPatch = lib.const ''
          substituteInPlace numpy/meson.build \
            --replace-fail 'py.full_path()' "'python'"

          # ehpic PIC needs wasm-EH, so -fno-exceptions is rejected; keep exceptions on.
          substituteInPlace numpy/_core/meson.build \
            --replace-fail "'-fno-exceptions',  # no exception support" "'-fexceptions',  # wasix ehpic: PIC needs wasm-EH"

          # long-double format is normally found by a run-probe (no exe_wrapper here); wasm32
          # is IEEE binary128 → supply IEEE_QUAD_LE directly.
          substituteInPlace numpy/_core/meson.build \
            --replace-fail "meson.get_external_property('longdouble_format', 'UNKNOWN')" "meson.get_external_property('longdouble_format', 'IEEE_QUAD_LE')"
        '';
      }
    )
    pyprev.numpy
  )
