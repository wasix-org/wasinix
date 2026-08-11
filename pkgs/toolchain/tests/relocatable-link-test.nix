# Regression test for wasixcc's relocatable-link path. The response file is
# intentional: nixpkgs' cc-wrapper uses one for long command lines.
{
  stdenvNoCC,
  toolchain,
}:
stdenvNoCC.mkDerivation {
  name = "wasixcc-relocatable-link-test";
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    ${toolchain.commonPreConfigure}

    cat > answer.c <<'C'
    int answer(void) { return 42; }
    C
    cat > main.c <<'C'
    int answer(void);
    int main(void) { return answer() == 42 ? 0 : 1; }
    C

    "$CC" -c answer.c -o answer.o
    printf '%s\n' '-r' 'answer.o' '-o' 'combined.o' > link.rsp
    "$CC" @link.rsp
    "$CC" main.c combined.o -o main.wasm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    test -s combined.o
    magic="$(od -An -tx1 -N4 main.wasm | tr -d ' \n')"
    [ "$magic" = "0061736d" ] || { echo "not a wasm module (magic=$magic)"; exit 1; }
    mkdir -p "$out"
    cp combined.o main.wasm "$out/"
    runHook postInstall
  '';

  meta.description = "wasixcc relocatable response-file link test";
}
