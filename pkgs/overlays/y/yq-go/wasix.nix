{
  exposeWasixPackage,
  extendPackage,
  package,
  wasmRename,
}:
exposeWasixPackage (
  wasmRename {wasmName = "yq";} (
    extendPackage package {
      vendorHash = "sha256-1UpQBsSVPQHdo5mukXGatLl7ru0qS4OS6ybuyMszJHc=";
      subPackages = ["."];
      tinygoBuildFlags = ["-opt=1"];
      # Go's checkPhase builds the tests; the Makefile check target invokes /bin/bash.
      wasixCheckPrebuild = ":";
      # go-json links against the standard Go compiler's private reflect ABI,
      # which TinyGo does not provide. These files use its public JSON API only.
      postPatch = ''
        substituteInPlace \
          pkg/yqlib/candidate_node_json.go \
          pkg/yqlib/decoder_json.go \
          pkg/yqlib/encoder_json.go \
          --replace-fail '"github.com/goccy/go-json"' '"encoding/json"'
      '';
      passthru.wasinix = {
        shipped = true;
        update.post = ["pkgs/overlays/y/yq-go/update-vendor-hash.py"];
      };
    }
  )
)
