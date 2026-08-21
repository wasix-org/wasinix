{
  exposePackage,
  extendPackage,
  package,
  wasmRename,
}:
exposePackage (
  wasmRename {wasmName = "gojq";} (
    extendPackage package {
      passthru.wasinix.shipped = true;
    }
  )
)
