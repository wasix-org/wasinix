{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.extendPackage pyprev.lazy-object-proxy {
  passthru.wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.pytest-benchmark];
}
