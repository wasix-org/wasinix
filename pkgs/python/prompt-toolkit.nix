{
  helpers,
  pyprev,
  ...
}:
helpers.extendPackage pyprev.prompt-toolkit {
  # create_pipe_input writes before registering the read end with asyncio;
  # Wasmer never reports that already-readable pipe to the selector.
  disabledTestPaths = ["tests/test_cli.py"];
}
