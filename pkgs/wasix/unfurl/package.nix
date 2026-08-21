{
  exposePackage,
  extendPackage,
  package,
  wasmRename,
}:
exposePackage (
  wasmRename {wasmName = "unfurl";} (
    extendPackage package {
      subPackages = ["."];
      passthru.wasinix.shipped = true;
    }
  )
)
