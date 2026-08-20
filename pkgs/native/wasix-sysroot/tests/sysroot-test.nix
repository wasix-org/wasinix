# Per-variant smoke test: compile a small C++ program against the variant's
# sysroot via its clang-wasix*.cmake_toolchain (reusing the same flag source) and
# assert a valid wasm object.
#
# Compile-only on purpose: linking needs the builtins/crt discovery wasixcc
# provides (raw clang + the bare toolchain file looks for compiler-rt in clang's
# resource dir, not the sysroot); link-test.nix covers link + run. This still
# exercises the fork clang, the ABI flags, the sysroot headers, and EH/PIC codegen.
{
  lib,
  stdenvNoCC,
  cmake,
  ninja,
  writeText,
  llvm,
  name,
  eh,
  pic,
  toolchainFile,
  sysroot,
}: let
  mainCpp = writeText "main.cpp" ''
    #include <vector>
    #include <numeric>
    ${lib.optionalString eh "#include <stdexcept>"}
    int wasix_test() {
      std::vector<int> v{1, 2, 3, 4};
      int s = std::accumulate(v.begin(), v.end(), 0);
    ${lib.optionalString eh ''try { throw std::runtime_error("boom"); } catch (const std::exception &) { s += 10; }''}
      return s;
    }
  '';

  cmakeLists = writeText "CMakeLists.txt" ''
    cmake_minimum_required(VERSION 3.20)
    project(wasix_test CXX)
    add_library(wasixtest OBJECT main.cpp)
  '';
in
  stdenvNoCC.mkDerivation {
    name = "wasix-test-${name}";
    dontUnpack = true;
    # We drive cmake by hand, so skip the hook's configure.
    dontUseCmakeConfigure = true;
    nativeBuildInputs = [cmake ninja llvm.clang-unwrapped llvm.lld llvm.llvm];

    buildPhase = ''
      runHook preBuild
      export CC=clang CXX=clang++ NM=llvm-nm AR=llvm-ar RANLIB=llvm-ranlib
      mkdir proj && cd proj
      cp ${mainCpp} main.cpp
      cp ${cmakeLists} CMakeLists.txt
      cmake -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=${toolchainFile} \
        -DCMAKE_SYSROOT=${sysroot} \
        -DCMAKE_POSITION_INDEPENDENT_CODE=${
        if pic
        then "ON"
        else "OFF"
      } \
        -DCMAKE_C_COMPILER_WORKS=ON \
        -DCMAKE_CXX_COMPILER_WORKS=ON \
        -B build -S .
      cmake --build build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      obj="$(find build -name '*.o' | head -1)"
      if [ -z "$obj" ]; then echo "no object produced:"; find build -type f; exit 1; fi
      magic="$(od -An -tx1 -N4 "$obj" | tr -d ' \n')"
      echo "object: $obj  magic: $magic"
      [ "$magic" = "0061736d" ] || { echo "not a wasm object (magic=$magic)"; exit 1; }
      mkdir -p "$out"
      cp "$obj" "$out/"
      runHook postInstall
    '';

    meta.description = "Sysroot compile smoke test for WASIX (${name} variant)";
  }
