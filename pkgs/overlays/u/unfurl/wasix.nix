{
  exposeWasixPackage,
  extendPackage,
  package,
  wasmRename,
}:
exposeWasixPackage (
  wasmRename {wasmName = "unfurl";} (
    extendPackage package {
      subPackages = ["."];
      passthru.wasinix.shipped = true;
    }
  )
)
