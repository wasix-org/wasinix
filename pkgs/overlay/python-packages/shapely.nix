# shapely for wasix. setup.py runs geos-config off PATH, finding the
# build-platform geos (native libgeos_c.so, wrong file type for wasm-ld);
# GEOS_CONFIG points it at the wasix geos, whose --clibs now lists -lgeos_c
# -lgeos (see packages/geos.nix), so the geos link libs come from there.
# libgeos.a's C++ runtime + EH personality (__wasm_lpad_context) refs are still
# hand-linked: setuptools links extensions with the C driver, so wasixcc adds
# no libc++, and the interpreter only exports the libc++ subset cpython uses.
{
  final,
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  env.GEOS_CONFIG = "${final.geos}/bin/geos-config";
  env.NIX_LDFLAGS = "-lc++ -lc++abi -lunwind";
}
pyprev.shapely
