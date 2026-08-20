{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru = {
    wasmer.name = "behavior";
    wasinix = {
      shipped = true;
    };
  };
}
