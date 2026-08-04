# A Fortran compile+link driver for wasix: the host flang emits wasm32 objects but
# has no wasix link wiring (sysroot/wasm-ld/crt), so link runs go through wasixcc.
{
  lib,
  writeShellScriptBin,
  flang,
  wasixcc,
  flangRt,
  # This profile's wasmExceptions ("legacy" | "yes" | "no") and PIC mode.
  wasmExceptions,
  pic ? false,
}: let
  flangCross = import ./flang-cross.nix {inherit lib;};
  env = import ./env.nix {inherit lib;};
  eh = wasmExceptions != "no";
  compileFlags = flangCross.mkFortranFlags {inherit pic eh;};
  wasixccEnv = env.exportsOf (env.profileEnv {inherit wasmExceptions pic;});
in
  # A link run may also carry Fortran sources (cmake's compile+link probe), so
  # those are compiled to temp objects before the whole set goes to wasixcc.
  (writeShellScriptBin "flang" ''
    for _a in "$@"; do case "$_a" in -c | -E | -S | -fsyntax-only)
      exec ${flang}/bin/flang ${compileFlags} "$@" ;;
    esac; done

    _srcs=()
    _rest=()
    for _a in "$@"; do
      case "$_a" in
        *.f | *.F | *.f90 | *.F90 | *.f95 | *.f03 | *.f08 | *.for | *.FOR) _srcs+=("$_a") ;;
        *) _rest+=("$_a") ;;
      esac
    done
    _tmp=$(mktemp -d)
    trap 'rm -rf "$_tmp"' EXIT
    _objs=()
    for _s in "''${_srcs[@]}"; do
      _o="$_tmp/$(basename "$_s").o"
      ${flang}/bin/flang ${compileFlags} -c "$_s" -o "$_o" || exit 1
      _objs+=("$_o")
    done
    ${wasixccEnv}
    ${wasixcc}/bin/wasixcc "''${_objs[@]}" "''${_rest[@]}" \
      -L${flangRt}/lib/wasm32-wasi -lflang_rt.runtime
  '')
  # What cc-wrapper reads to wrap this as a Fortran-only compiler: langFortran
  # installs fortran-hook.sh, which exports FC, and isFlang routes package flags
  # through NIX_FFLAGS_COMPILE so C-only flags never reach the Fortran driver.
  .overrideAttrs (old: {
    passthru =
      old.passthru
      // {
        langC = false;
        langCC = false;
        langFortran = true;
        isFlang = true;
        hardeningUnsupportedFlags = ["zerocallusedregs" "stackclashprotection"];
      };
  })
