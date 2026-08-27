{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  cmakeFlags = old: old ++ ["-DBUILD_SHARED_LIB=OFF"];
  postPatch = ''
    substituteInPlace include/tidyplatform.h \
      --replace-fail '#    if defined(CYGWIN_OS)' '#    if defined(__wasi__) || defined(CYGWIN_OS)' \
      --replace-fail '#    if defined(SOLARIS_OS)' '#    if defined(__wasi__) || defined(SOLARIS_OS)'
  '';
}
