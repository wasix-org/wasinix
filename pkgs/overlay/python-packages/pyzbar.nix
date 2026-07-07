# pyzbar for wasix. nixpkgs' postPatch hardcodes the libzbar path via
# `extensions.sharedLibrary` (unset for wasm32, killing eval) and rebuilds its
# own zbar via zbar.override, which would drop the overlay's shared-lib
# tweaks; hand it a zbar whose .override is inert and substitute the dlopen
# path ourselves (the wasix zbar builds a real libzbar.so, see
# overlay/packages/zbar.nix).
{
  final,
  lib,
  pyprev,
  ...
}: let
  zbar = final.zbar // {override = _: final.zbar;};
in
  (pyprev.pyzbar.override {inherit zbar;}).overridePythonAttrs (o: {
    postPatch = ''
      substituteInPlace pyzbar/zbar_library.py \
        --replace-fail "find_library('zbar')" '"${lib.getLib final.zbar}/lib/libzbar.so"'
    '';
  })
