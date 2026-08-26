# zstd's build uses bash + grep as *host* deps (not spliced to the build
# platform), so the defaults would build a wasm bash/grep (→ pcre2) that can't
# link for WASI. Pin them to the build platform explicitly.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
}:
exposeWasixPackage (
  extendPackage (package.override {
    bashNonInteractive = packages.sameProfile.buildPackages.bashNonInteractive;
    gnugrep = packages.sameProfile.buildPackages.gnugrep;
  }) {}
)
