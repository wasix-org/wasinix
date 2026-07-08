# Make a wheel self-contained: copy native artifacts it loads at runtime (a
# ctypes/cffi .so, a spawned .wasm) INTO the wheel's package dir and rewrite
# the loader to resolve them relative to __file__, so `pip install` works with
# no /nix/store mounted (the store paths don't exist on a real wasix target).
# The copy is source-level (postPatch), before the wheel is built, so the file
# lands inside the .whl; a post-install inject would miss the distributed wheel.
#
# Usage (a libTweaks fragment):
#   bundle = import ./lib/bundle.nix {inherit lib;};
#   helpers.libTweaks (bundle.bundleNative {
#     pkg = "pyzbar";                                  # top-level source package dir
#     files = [ { src = "${final.zbar.lib}/lib/libzbar.so"; } ];
#     rewrites = [
#       # short form: replace `from` with a __file__-relative path to `load`
#       { file = "pyzbar/zbar_library.py"; from = "find_library('zbar')"; load = "libzbar.so"; }
#       # long form: replace `from` with arbitrary `to` (use bundle.relPath for
#       # the __file__-relative path where the loader takes an arg mid-call)
#       # { file = "..."; from = "load_lib(\"gmp\","; to = "load_lib(${bundle.relPath "libgmp.so.10"},"; }
#     ];
#   }) drv;
#
# setuptools needs the natives declared as package_data; flit/hatchling include
# package-dir files already, so the appended setup.cfg section is harmless there.
{lib}: rec {
  # A python expression: the bundled `name`, resolved next to the current file.
  relPath = name: "__import__('os').path.join(__import__('os').path.dirname(__file__), ${builtins.toJSON name})";

  bundleNative = {
    pkg,
    files,
    rewrites ? [],
  }: {
    postPatch = let
      copies =
        lib.concatMapStringsSep "\n" (
          f: let
            name = f.name or (builtins.baseNameOf f.src);
          in "install -Dm644 ${f.src} ${pkg}/${name}"
        )
        files;
      subst =
        lib.concatMapStringsSep "\n" (
          r:
            "substituteInPlace ${r.file} --replace-fail "
            + lib.escapeShellArg r.from
            + " "
            + lib.escapeShellArg (r.to or (relPath r.load))
        )
        rewrites;
    in ''
      ${copies}
      ${subst}
      cat >> setup.cfg <<'WASIX_BUNDLE_EOF'

      [options.package_data]
      * = *.so, *.so.*, *.wasm, *.dylib
      WASIX_BUNDLE_EOF
    '';
  };
}
