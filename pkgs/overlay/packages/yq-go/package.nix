{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "yq";} (
  helpers.libTweaks {
    vendorHash = "sha256-1UpQBsSVPQHdo5mukXGatLl7ru0qS4OS6ybuyMszJHc=";
    subPackages = ["."];
    tinygoBuildFlags = ["-opt=1"];
    postPatch = ''
      substituteInPlace \
        pkg/yqlib/candidate_node_json.go \
        pkg/yqlib/decoder_json.go \
        pkg/yqlib/encoder_json.go \
        --replace-fail '"github.com/goccy/go-json"' '"encoding/json"'
    '';
    passthru.wasix = {
      shipped = true;
      postUpdateHook = ["pkgs/overlay/packages/yq-go/update-vendor-hash.py"];
    };
  }
  prev.yq-go
)
