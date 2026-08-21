{exposeExtendedPackage}:
exposeExtendedPackage {
  patches = [./patches/test-with-system-brotli.patch];

  postPatch = ''
    substituteInPlace src/brotlicffi/_build.py \
      --replace-fail "libraries.append('stdc++')" "libraries.append('c++')" \
      --replace-fail "libraries = ['brotlienc', 'brotlidec']" "libraries = ['brotlienc', 'brotlidec', 'brotlicommon']"
  '';
}
