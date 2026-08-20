# aiohappyeyeballs for wasix. nixpkgs runs a Sphinx docs pass whose myst-parser doesn't
# cross-build, taking the wheel (and aiohttp) down. Drop the docs (cf. pynacl.nix).
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.aiohappyeyeballs (helpers.python.dropSphinxDocs ["myst"])
