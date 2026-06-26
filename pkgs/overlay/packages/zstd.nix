# zstd's build uses bash + grep as *host* deps (not spliced to the build
# platform), so the defaults would build a wasm bash/grep (→ pcre2) that can't
# link for WASI. Pin them to the build platform explicitly.
{
  final,
  prev,
  helpers,
  ...
}:
helpers.libTweaks {} (prev.zstd.override {
  bashNonInteractive = final.buildPackages.bashNonInteractive;
  gnugrep = final.buildPackages.gnugrep;
})
