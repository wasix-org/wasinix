# nixpkgs' pypandoc patches in a native pandoc store path and pulls texlive for
# its tests; drop both so it keeps upstream's PATH lookup (finds our wasm pandoc
# at runtime) and stays a relocatable pure wheel.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = _: [];
  nativeCheckInputs = _: [];
  passthru.wasix.installCheck = false;
}
pyprev.pypandoc
