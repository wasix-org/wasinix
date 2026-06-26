# runtimeShellPackage null: don't pull a target-side bash-static.
{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "gzip";} (
  helpers.libTweaks {
    overrideAttrs = old: {
      # Drop nixpkgs' preFixup: it PATH-injects the gunzip/zcat shell scripts
      # (which we delete) and wrapProgram's bin/gzip (which we rename to
      # gzip.wasm), so it would fail. gzip.wasm is a standalone binary.
      preFixup = "";
      postInstall =
        (old.postInstall or "")
        + ''
          rm -f "$out/bin/gunzip" "$out/bin/zcat"
        '';
      # gunzip/zcat ship as gzip.wasm invoked with fixed args (we deleted the
      # shell-script siblings), so the command list can't be glob-derived.
      passthru =
        (old.passthru or {})
        // {
          wasmer.commands = [
            {
              name = "gzip";
              module = "gzip";
              wasm = "gzip.wasm";
              output = "gzip.wasm";
            }
            {
              name = "gunzip";
              module = "gunzip";
              wasm = "gzip.wasm";
              output = "gunzip.wasm";
              mainArgs = ["-d" "-f"];
            }
            {
              name = "zcat";
              module = "zcat";
              wasm = "gzip.wasm";
              output = "zcat.wasm";
              mainArgs = ["-d" "-c" "-f"];
            }
          ];
        };
    };
  } (prev.gzip.override {runtimeShellPackage = null;})
)
