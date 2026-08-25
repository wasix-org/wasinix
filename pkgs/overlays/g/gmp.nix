{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  # t-nextprime and t-scanf fail under wasmer (wasix scanf gaps); XFAIL so the
  # rest of the suite still runs.
  checkFlagsArray = [''XFAIL_TESTS=t-nextprime t-scanf''];
  # t-locale interposes localeconv, which wasix-libc defines non-weak, so
  # wasm-ld fails ("duplicate symbol: localeconv") and takes the whole test
  # build with it; XFAIL covers run failures only, so drop the test. Patch
  # Makefile.in too: the tarball ships it generated and configure uses it.
  postPatch = ''
    substituteInPlace tests/misc/Makefile.am \
      --replace-fail "t-printf t-scanf t-locale" "t-printf t-scanf"
    substituteInPlace tests/misc/Makefile.in \
      --replace-fail "t-printf\$(EXEEXT) t-scanf\$(EXEEXT) t-locale\$(EXEEXT)" \
                     "t-printf\$(EXEEXT) t-scanf\$(EXEEXT)"
  '';
  passthru.wasinix.checks.captured.timeout = 3600;
}
