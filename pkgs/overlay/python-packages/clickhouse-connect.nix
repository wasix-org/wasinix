{
  pyfinal,
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.clickhouse-connect {
  # Replaces the stashed check inputs: the inherited numpy is the
  # build-platform one; the unit tests also import sqlalchemy and pandas.
  passthru = old:
    old
    // {
      wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.numpy pyfinal.sqlalchemy pyfinal.pandas];
    };
  # wasix sockets answer IPv4 loopback only; the IPv6 test fails on the bind
  disabledTests = ["TestIPv6DataType"];
}
