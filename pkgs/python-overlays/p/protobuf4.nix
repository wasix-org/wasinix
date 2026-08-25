# protobuf's setup.py links the pyext extension against libprotobuf alone, which
# on a shared-object platform carries abseil transitively. A static cross build
# has no such closure, so wasm-ld turns each abseil reference into a module
# import and loading the extension aborts on the first missing export.
{
  exposeExtendedPackage,
  pkgs,
}:
exposeExtendedPackage {
  buildInputs = [pkgs.abseil-cpp];
  preBuild = ''
    for _archive in ${pkgs.abseil-cpp}/lib/libabsl_*.a; do
      _name=''${_archive##*/}
      _name=''${_name#lib}
      NIX_LDFLAGS="$NIX_LDFLAGS -l''${_name%.a}"
    done
    export NIX_LDFLAGS="$NIX_LDFLAGS -L${pkgs.abseil-cpp}/lib"
  '';
}
