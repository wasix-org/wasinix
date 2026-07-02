# Two _build.py link fixes: link llvm libc++ (-lc++), not GNU -lstdc++, and
# add brotlicommon (BrotliDefaultAlloc/FreeFunc live there; without it the .so
# fails at import with a missing GOT export).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace src/brotlicffi/_build.py \
      --replace-fail "libraries.append('stdc++')" "libraries.append('c++')" \
      --replace-fail "libraries = ['brotlienc', 'brotlidec']" "libraries = ['brotlienc', 'brotlidec', 'brotlicommon']"
  '';
}
pyprev.brotlicffi
