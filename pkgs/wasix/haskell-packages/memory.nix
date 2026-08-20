{
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.memory (old: {
  patches = (old.patches or []) ++ [./patches/memory/wasi.patch];
})
