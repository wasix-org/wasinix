{
  testLib,
  toolchain,
}:
testLib.mkWasixRun {
  name = "wasixcc-asyncify-eh";
  wasixPkgs = [];
  script = ''
    ${toolchain.commonPreConfigure}
    export WASIXCC_RUN_WASM_OPT=yes
    export WASIXCC_WASM_OPT_FLAGS=--asyncify

    cat > main.cpp <<'CPP'
    #include <stdexcept>

    int main() {
      try {
        throw std::runtime_error("boom");
      } catch (const std::exception &) {
        return 0;
      }
    }
    CPP

    "$CXX" main.cpp -o main.wasm
  '';
  broken = "Binaryen Asyncify aborts while flattening Wasm EH instructions";
}
