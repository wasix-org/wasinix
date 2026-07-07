# shapely for wasix. setup.py runs geos-config off PATH, finding the
# build-platform geos (native libgeos_c.so, wrong file type for wasm-ld);
# GEOS_CONFIG points it at the wasix geos. NIX_LDFLAGS lands after -lgeos_c:
# -lgeos closes libgeos_c.a's references, and -lc++/-lc++abi/-lunwind close
# libgeos.a's C++ runtime + EH personality (__wasm_lpad_context) references
# (setuptools links extensions with the C driver, which won't add them).
{
  final,
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  env.GEOS_CONFIG = "${final.geos}/bin/geos-config";
  env.NIX_LDFLAGS = "-lgeos -lc++ -lc++abi -lunwind";
}
pyprev.shapely
