# End-to-end OpenMP test: compile a `#pragma omp parallel` C program through
# wasixcc, link it against the cross-built libomp, then run under wasmer. The
# reduction is correct even serially, so the thread count is what reports spawning.
{
  stdenvNoCC,
  wasmer,
  toolchain,
  openmp,
}: let
  # wasmer can't execute the *legacy* `try` opcode (no feature flag for it), and
  # libomp is built with -fwasm-exceptions, so legacy-EH profiles are link-only.
  canRun = (toolchain.wasmExceptions or "no") != "legacy";
in
  stdenvNoCC.mkDerivation {
    name = "wasix-openmp-test-${toolchain.profileName}";
    dontUnpack = true;

    # -fopenmp on the link line is the whole contract: the driver names libomp
    # and the libc++/libc++abi its objects reference. Finding the library is the
    # build's job, as it is for any other -L.
    buildPhase = ''
      runHook preBuild
      ${toolchain.commonPreConfigure}
      cat > omp.c <<'C'
      #include <stdio.h>
      #include <omp.h>
      int main(void) {
        int max_threads = omp_get_max_threads();
        int threads_ran = 0;
        long sum = 0;
        #pragma omp parallel reduction(+ : sum)
        {
          #pragma omp single
          threads_ran = omp_get_num_threads();
          #pragma omp for
          for (int i = 1; i <= 1000; i++)
            sum += i;
        }
        printf("openmp sum=%ld max_threads=%d threads_ran=%d\n", sum, max_threads,
               threads_ran);
        return sum == 500500 ? 0 : 1;
      }
      C

      "$CC" -fopenmp -I${openmp}/include -c omp.c -o omp.o
      "$CC" -fopenmp omp.o -L${openmp}/lib -o omp.wasm
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      magic="$(od -An -tx1 -N4 omp.wasm | tr -d ' \n')"
      [ "$magic" = "0061736d" ] || { echo "not a wasm module (magic=$magic)"; exit 1; }

      ${
        if canRun
        then ''
          export HOME="$TMPDIR"
          export WASMER_DIR="$TMPDIR/.wasmer"
          out_text="$(${wasmer}/bin/wasmer run --env OMP_NUM_THREADS=4 omp.wasm)"
          echo "program output: $out_text"
          case "$out_text" in
            *"openmp sum=500500"*) echo "ran OK under wasmer" ;;
            *) echo "unexpected output"; exit 1 ;;
          esac
        ''
        else ''echo "link-only (legacy-EH: wasmer can't execute the legacy try opcode)"''
      }

      mkdir -p "$out"
      cp omp.wasm "$out/"
      runHook postInstall
    '';

    meta.description = "libomp compile/link/run test for the ${toolchain.profileName} profile";
  }
