# pyzbar for wasix. Bundle libzbar.so into the wheel and load it relative to
# __file__ so `pip install pyzbar` works with no /nix/store (see lib/bundle.nix);
# nixpkgs would rebuild its own zbar via zbar.override, so hand it ours inert.
{
  final,
  lib,
  pyprev,
  helpers,
  ...
}: let
  bundle = import ./lib/bundle.nix {inherit lib;};
  zbar = final.zbar // {override = _: final.zbar;};
in
  helpers.libTweaks (bundle.bundleNative {
    pkg = "pyzbar";
    files = [{src = "${lib.getLib final.zbar}/lib/libzbar.so";}];
    rewrites = [
      {
        file = "pyzbar/zbar_library.py";
        from = "find_library('zbar')";
        load = "libzbar.so";
      }
    ];
  }) (
    # drop nixpkgs' postPatch: it references extensions.sharedLibrary (unset for
    # wasm32) and rewrites find_library itself, both superseded here.
    (pyprev.pyzbar.override {pkgs = {inherit zbar;};}).overridePythonAttrs (_: {postPatch = "";})
  )
