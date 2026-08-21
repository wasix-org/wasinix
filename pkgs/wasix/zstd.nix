# zstd's build uses bash + grep as *host* deps (not spliced to the build
# platform), so the defaults would build a wasm bash/grep (→ pcre2) that can't
# link for WASI. Pin them to the build platform explicitly.
{
  exposePackage,
  extendPackage,
  package,
  packages,
}:
exposePackage (
  extendPackage (package.override {
    bashNonInteractive = packages.sameProfile.buildPackages.bashNonInteractive;
    gnugrep = packages.sameProfile.buildPackages.gnugrep;
  }) {}
)
