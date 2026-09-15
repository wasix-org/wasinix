# bcrypt for wasix (setuptools-rust/pyo3); vendored-crate patches via the hook.
# A history release whose committed lock does not build is re-vendored from a lock
# kept beside this unit (locks/<version>.lock). fetchCargoVendor reads
# $sourceRoot/Cargo.lock, so the vendor takes sourceRoot rather than nixpkgs'
# cargoRoot for that rebase, which is where the replacement lock lands. The build
# reads cargoRoot/Cargo.lock, so postPatch drops the same lock there too; without
# it the build's lock and the re-vendored deps disagree (cargoHash out of date).
{
  exposeExtendedPackage,
  package,
  lib,
}: let
  isHistory = (package.passthru.wasix.historySpec or null) != null;
in
  exposeExtendedPackage (lib.optionalAttrs isHistory {
    cargoDeps = prev:
      prev.override {
        cargoRoot = null;
        sourceRoot = "${package.src.name}/src/_bcrypt";
      };
    postPatch = ''
      if [ -f ${./locks}/"$version".lock ]; then
        cp ${./locks}/"$version".lock src/_bcrypt/Cargo.lock
      fi
    '';
  })
