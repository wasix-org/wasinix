# pyopenssl for wasix. nixpkgs builds it multi-output for the sphinx docs and
# attaches propagatedBuildInputs to dev, so a dependent propagating pyopenssl gets
# a dev output with no python module and `import OpenSSL` raises ModuleNotFoundError.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks (
  helpers.python.dropSphinxDocs []
  # dev holds no module, so keep out (module) + dist (wheel) only.
  // {outputs = _: ["out" "dist"];}
)
pyprev.pyopenssl
