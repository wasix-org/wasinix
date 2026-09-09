# gdbm's command-line tools call fork, which wasix cannot provide under
# Wasm-EH. Python links the library and never runs them, so drop the tools and
# the test programs that link them; the info output still needs doc.
{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  postPatch = ''
    substituteInPlace Makefile.in \
      --replace-fail 'SUBDIRS = po src tools doc $(MAYBE_COMPAT) tests' \
                     'SUBDIRS = po src doc $(MAYBE_COMPAT)'
  '';
}
