{exposeExtendedPackage}:
exposeExtendedPackage {
  # The interpreter is built without IPv6, so inet_pton(AF_INET6, ...) raises.
  # --deselect, not disabledTests: the hook word-splits its entries.
  pytestFlags = ["--deselect=tests/test_address.py::IPv6Tests::test_valid"];
}
