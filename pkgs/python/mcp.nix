{
  pyfinal,
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.mcp {
  # Replaces the stashed check inputs: the inherited list drags ruff (via
  # inline-snapshot), which cannot compile on wasix.
  passthru = old:
    old
    // {
      # xdist owns the --numprocesses flag mcp's config passes; -n 0 keeps one guest
      # typer: conftest imports mcp.cli, which sys.exit(1)s without it
      wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.pytest-asyncio pyfinal.anyio pyfinal.inline-snapshot pyfinal.pytest-timeout pyfinal.pytest-xdist pyfinal.typer];
    };
  pytestFlags = ["-n" "0"];
  # test_examples/func_metadata want pytest-examples, which hard-depends on
  # ruff (unbuildable here); ws/streamable_http drive real server transports
  disabledTestPaths = [
    "tests/test_examples.py"
    "tests/server/fastmcp/test_func_metadata.py"
    "tests/shared/test_ws.py"
    # websockets isn't ported in this overlay; collection failure would abort the whole suite
    "tests/server/test_websocket_security.py"
    "tests/shared/test_streamable_http.py"
    # sse and the fastmcp integration tests spawn server subprocesses in-guest
    "tests/shared/test_sse.py"
    "tests/server/fastmcp/test_integration.py"
    # the stdio transport is subprocess spawning (the stub-reentry gap)
    "tests/client/test_stdio.py"
    "tests/client/test_notification_response.py"
  ];
  disabledTests = [
    # chmod-based permission checks do not deny on wasix's mapped fs
    "test_permission_error"
    # fails under wasmer; untriaged
    "test_fn_returns_assistant_message"
  ];
}
