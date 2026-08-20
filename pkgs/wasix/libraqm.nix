# libraqm's library builds fine, but its test executable (raqm-test, a C program)
# links harfbuzz, which now carries wasm-EH (see harfbuzz.nix), so it needs the
# C++ EH runtime (std::terminate) that a plain C link doesn't pull. Nothing here
# runs the test; pillow/matplotlib use only the library. Skip the test build.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.libraqm {
  doCheck = false;
  mesonFlags = ["-Dtests=false"];
}
