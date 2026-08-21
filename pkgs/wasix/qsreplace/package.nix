{
  exposePackage,
  extendPackage,
  package,
  wasmRename,
}:
exposePackage (
  wasmRename {wasmName = "qsreplace";} (
    extendPackage package {
      subPackages = ["."];
      passthru.wasinix.shipped = true;
    }
  )
)
