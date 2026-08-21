{
  lib,
  stdenvNoCC,
  tinygo,
  wasix-llvm,
  wasmer,
}:
stdenvNoCC.mkDerivation {
  name = "wasix-tinygo-test";
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"

    version="$(${lib.getExe' tinygo "tinygo"} version)"
    echo "$version"
    case "$version" in
      *"LLVM version ${wasix-llvm.passthru.llvmVersion}"*) ;;
      *) echo "tinygo does not use the WASIX LLVM fork"; exit 1 ;;
    esac

    cat > hello.go <<'GO'
    package main

    import "fmt"

    func main() {
        fmt.Println("hello from tinygo")
    }
    GO
    ${lib.getExe' tinygo "tinygo"} build -target=wasip1 -o hello.wasm hello.go
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    magic="$(od -An -tx1 -N4 hello.wasm | tr -d ' \n')"
    [ "$magic" = "0061736d" ] || { echo "not a wasm module (magic=$magic)"; exit 1; }

    export WASMER_DIR="$TMPDIR/.wasmer"
    output="$(${lib.getExe wasmer} run hello.wasm)"
    echo "program output: $output"
    [ "$output" = "hello from tinygo" ]

    install -Dm644 hello.wasm "$out/bin/hello.wasm"
    runHook postInstall
  '';

  meta.description = "TinyGo and WASIX LLVM compile/run check";
}
