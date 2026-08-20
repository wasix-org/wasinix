# fribidi's bin/ subdir unconditionally compiles the bundled GNU getopt
# (getopt.c/getopt1.c), whose symbols collide with wasix-libc's getopt at link
# (duplicate getopt/getopt_long/optarg/...). Nothing here needs the CLI;
# libfribidi is the only consumer. bin=false + tests=false skip the bin/ subdir
# entirely (meson gates it on `bin or tests`).
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.fribidi {
  # no suite: the tests drive the bin/ CLIs skipped above.
  doCheck = false;
  mesonFlags = ["-Dbin=false" "-Dtests=false"];
}
