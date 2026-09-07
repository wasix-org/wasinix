# A dynamic main built with WASIXCC_INCLUDE_CPP_SYMBOLS carries the C++ runtime on
# behalf of the side modules dlopened into it: a side module imports its runtime
# as GOT entries, wasm-ld resolves none of them at link time, and a main holding
# only the subset its own objects reference fails at load with
# "Unresolved global 'GOT.mem'". Compile a side module with the same profile and
# require the main to offer every symbol it asks for.
#
# Usage:
#   cxxRuntimeCheck {
#     name = "exnrefEhpic-python313-3.13.15";
#     package = <the dynamic main>;
#     stdenv = <the same profile's wasix stdenv>;
#   }
{
  runCommand,
  python3,
}: {
  name,
  package,
  stdenv,
}: let
  # std::string, a throw/catch and a dynamic_cast between them reach the parts of
  # the runtime a main can only hand over whole: operator new, the exception
  # tables, and the type_info vtables.
  probe = stdenv.mkDerivation {
    name = "cxx-runtime-probe-${name}";
    dontUnpack = true;

    buildPhase = ''
      runHook preBuild
      cat > probe.cpp <<'CPP'
      #include <stdexcept>
      #include <string>

      struct Base { virtual ~Base() {} };
      struct Derived : Base {};

      extern "C" int probe(const char *text) {
        try {
          std::string value(text);
          if (value.empty()) throw std::runtime_error("empty");
          Base *base = new Derived();
          int size = dynamic_cast<Derived *>(base) ? (int)value.size() : -1;
          delete base;
          return size;
        } catch (const std::exception &error) {
          return -(int)std::string(error.what()).size();
        }
      }
      CPP
      "$CXX" -shared probe.cpp -o probe.so
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 probe.so "$out/probe.so"
      runHook postInstall
    '';
  };
in
  runCommand "cxx-runtime-${name}" {} ''
    for main in ${package}/bin/*.wasm; do
      ${python3.interpreter} ${../../python/wheels/check-dynamic-imports.py} "$main" ${probe}
    done > "$out"
  ''
