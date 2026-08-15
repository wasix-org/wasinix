# End-to-end Fortran test through the profile's compile+link driver, then wasmer.
{
  stdenvNoCC,
  wasmer,
  toolchain,
  wasixflang,
}:
stdenvNoCC.mkDerivation {
  name = "wasix-flang-rt-test-${toolchain.profileName}";
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    ${toolchain.commonPreConfigure}
    cat > hello.f90 <<'F90'
    program hello
      implicit none
      integer :: i, total
      total = 0
      do i = 1, 5
        total = total + i
      end do
      print *, "Hello from Fortran on WASIX, sum(1..5)=", total
    end program hello
    F90

    ${wasixflang}/bin/flang hello.f90 -o hello.wasm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    magic="$(od -An -tx1 -N4 hello.wasm | tr -d ' \n')"
    [ "$magic" = "0061736d" ] || { echo "not a wasm module (magic=$magic)"; exit 1; }

    export HOME="$TMPDIR"
    export WASMER_DIR="$TMPDIR/.wasmer"
    out_text="$(${wasmer}/bin/wasmer run --quiet hello.wasm)"
    echo "program output: $out_text"
    case "$out_text" in
      *"Hello from Fortran on WASIX"*"15"*) echo "ran OK under wasmer" ;;
      *) echo "unexpected output"; exit 1 ;;
    esac

    mkdir -p "$out"
    cp hello.wasm "$out/"
    runHook postInstall
  '';

  meta.description = "flang + flang-rt compile/link/run test for the ${toolchain.profileName} profile";
}
