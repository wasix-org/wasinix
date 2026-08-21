{
  exposePackage,
  extendPackage,
  package,
  packages,
  wasmRename,
}:
exposePackage (
  wasmRename {
    wasmName = "sed";
    posixAlias = true;
  } (
    extendPackage package {
      passthru.wasinix.shipped = true;
      meta.platforms = _: packages.sameProfile.lib.platforms.all;
      # sed's build compiles the bundled gnulib-tests, whose
      # getlocalename_l-unsafe.c #errors on unknown platforms (wasix). Return the
      # "C" locale, matching the gettext overlay's fix.
      postPatch = ''
        substituteInPlace gnulib-tests/getlocalename_l-unsafe.c \
          --replace-fail \
          ' #error "Please port gnulib getlocalename_l-unsafe.c to your platform! Report this to bug-gnulib."' \
          '  return (struct string_with_storage) { "C", STORAGE_INDEFINITE };'
      '';
    }
  )
)
