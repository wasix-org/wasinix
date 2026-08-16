{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.pytest-benchmark];
}
pyprev.lazy-object-proxy
