# pyzbar for wasix. Bundle libzbar.so into the wheel and load it relative to
# __file__ so `pip install pyzbar` works with no /nix/store (see lib/bundle.nix);
# nixpkgs would rebuild its own zbar via zbar.override, so hand it ours inert.
{
  exposePackage,
  extendPackage,
  package,
  pkgs,
  lib,
}:
exposePackage (
  let
    bundle = import ./lib/bundle.nix {inherit lib;};
    zbar = pkgs.zbar // {override = _: pkgs.zbar;};
  in
    extendPackage (
      # drop nixpkgs' postPatch: it references extensions.sharedLibrary (unset for
      # wasm32) and rewrites find_library itself, both superseded here.
      (package.override {pkgs = {inherit zbar;};}).overridePythonAttrs (_: {postPatch = "";})
    ) (bundle.bundleNative {
      pkg = "pyzbar";
      files = [{src = "${lib.getLib pkgs.zbar}/lib/libzbar.so";}];
      rewrites = [
        {
          file = "pyzbar/zbar_library.py";
          from = "find_library('zbar')";
          load = "libzbar.so";
        }
      ];
    })
)
