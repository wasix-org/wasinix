# libraqm (pillow/matplotlib's text shaper) needs harfbuzz core + freetype +
# fribidi, not hb-glib or Graphite shaping. Two optional harfbuzz features pull
# packages that don't build on wasix:
#   - glib (hb-glib): glib's bundled gnulib and GIO assume POSIX facilities
#     wasi-libc lacks (e.g. socket ancillary data).
#   - graphite2: its docs build a cross python env that fails to compile.
# Disable both and drop the inputs rather than port them. Tracked in WASIX-TODO.md.
# Also, harfbuzz forces -fno-exceptions (meson.build + cpp_eh=none), which wasixcc
# rejects in the ehpic PIC profiles (PIC requires wasm-EH); keep exceptions on,
# as numpy does.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # tests/utilities are executables that link the now-exception-carrying library
  # and need the C++ EH runtime, which the off profile lacks (std::terminate
  # undefined); the library itself is all consumers use, so skip them.
  mesonFlags = ["-Dglib=disabled" "-Dgobject=disabled" "-Dcpp_eh=default" "-Dtests=disabled" "-Dutilities=disabled"];
  postPatch = ''
    substituteInPlace meson.build \
      --replace-fail "'-fno-exceptions'," "'-fexceptions',"
  '';
} (prev.harfbuzz.override {
  glib = null;
  withGraphite2 = false;
})
