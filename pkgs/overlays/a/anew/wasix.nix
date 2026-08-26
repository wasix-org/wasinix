{
  exposeWasixPackage,
  package,
  wasmRename,
}:
exposeWasixPackage (
  wasmRename {wasmName = "anew";} (
    package.overrideAttrs (_old: {passthru.wasinix.shipped = true;})
  )
)
