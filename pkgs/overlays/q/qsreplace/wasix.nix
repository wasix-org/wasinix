{
  exposeWasixPackage,
  extendPackage,
  package,
  wasmRename,
}:
exposeWasixPackage (
  wasmRename {wasmName = "qsreplace";} (
    extendPackage package {
      subPackages = ["."];
      passthru.wasinix.shipped = true;
    }
  )
)
