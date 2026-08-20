{
  pkgs,
  wasmer,
}: let
  rawWasm = import ../runners/raw-wasm.nix {inherit pkgs;};
in {
  stub = rawWasm.unbound;
  run = rawWasm.withRuntime wasmer;
}
