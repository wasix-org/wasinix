{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  propagatedBuildInputs = [pyfinal.starlette];
}
pyprev.sse-starlette
