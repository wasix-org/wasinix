{
  exposeWasixPackage,
  extendPackage,
  package,
  wasmRename,
}:
exposeWasixPackage (
  wasmRename {wasmName = "gojq";} (
    extendPackage package {
      passthru.wasinix.shipped = true;
    }
  )
)
