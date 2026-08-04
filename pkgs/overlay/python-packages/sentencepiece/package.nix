# sentencepiece python binding for wasix. setup.py probes a literal `pkg-config`,
# missing the wasix cross wrapper, and falls back to build_bundled.sh, which fails
# cross; the patch makes it honor $PKG_CONFIG.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/setup-honor-pkg-config.patch];
}
pyprev.sentencepiece
