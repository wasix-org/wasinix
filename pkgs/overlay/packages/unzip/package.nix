# unzip includes <unistd.h> only for the platforms its own macros name, and the
# generic make target names none of them, so isatty and the utimbuf struct go
# undeclared.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/wasi-unistd-include.patch];
}
prev.unzip
