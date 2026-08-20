{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.extendPackage pyprev.sse-starlette {
  propagatedBuildInputs = [pyfinal.starlette];
}
