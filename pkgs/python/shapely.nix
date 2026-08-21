# shapely for wasix. setup.py runs geos-config off PATH, finding the
# build-platform geos (native libgeos_c.so, wrong file type for wasm-ld);
# GEOS_CONFIG points it at the wasix geos, whose --clibs now lists -lgeos_c
# -lgeos (see packages/geos.nix), so the geos link libs come from there.
# libgeos.a's C++ runtime + EH personality (__wasm_lpad_context) refs are still
# hand-linked: setuptools links extensions with the C driver, so wasixcc adds
# no libc++, and the interpreter only exports the libc++ subset cpython uses.
{
  exposeExtendedPackage,
  pkgs,
}:
exposeExtendedPackage {
  env.GEOS_CONFIG = "${pkgs.geos}/bin/geos-config";
  env.NIX_LDFLAGS = "-lc++ -lc++abi -lunwind";
  # Replaces nixpkgs' preCheck: its `cd $out` breaks in the run-only check
  # derivation, where $out is unwritten; resolve the installed tree off the
  # guest PYTHONPATH so the source dir cannot shadow the extension.
  preCheck = _: ''
    _site=$(echo "$PYTHONPATH" | tr ':' '\n' | grep -m1 -- '-shapely-.*site-packages$')
    cd "$_site"
  '';
  # Suite off: the tests reach geos and die on a wasm out-of-bounds memory
  # access, a real cross geos/shapely defect (WASIX-TODO.md).
  passthru.wasinix.checks.captured.install = false;
}
