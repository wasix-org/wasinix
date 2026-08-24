# Regression test: a versioned shared library is a link input, not a source.
#
# `Path::extension` only sees the final component, so libfoo.so.1.2.3 (what
# cmake emits for a target carrying a SOVERSION, e.g. pyarrow's
# libarrow_python.so.2100.0.0.0) used to be partitioned as a compiler input.
# wasixcc then expected a compiled <tmp>/libfoo.so.1.2.3.o that nothing
# produces and the link died with "cannot open". Fixed in
# ../wasixcc-versioned-soname-inputs.patch; this keeps it fixed.
#
# PIC profiles only: a shared library needs -fPIC.
{
  stdenvNoCC,
  toolchain,
}:
stdenvNoCC.mkDerivation {
  name = "wasix-versioned-soname-test-${toolchain.profileName}";
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    ${toolchain.commonPreConfigure}
    cat > lib.c <<'C'
    int answer(void) { return 42; }
    C
    cat > main.c <<'C'
    int answer(void);
    int main(void) { return answer() == 42 ? 0 : 1; }
    C

    # the versioned spelling is the whole point: link against it by that name
    "$CC" -shared -fPIC lib.c -o libanswer.so.1.2.3
    "$CC" main.c libanswer.so.1.2.3 -o main.wasm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    magic="$(od -An -tx1 -N4 main.wasm | tr -d ' \n')"
    [ "$magic" = "0061736d" ] || { echo "not a wasm module (magic=$magic)"; exit 1; }
    mkdir -p "$out"
    cp main.wasm libanswer.so.1.2.3 "$out/"
    runHook postInstall
  '';

  meta.description = "wasixcc versioned-soname link input test for the ${toolchain.profileName} profile";
}
