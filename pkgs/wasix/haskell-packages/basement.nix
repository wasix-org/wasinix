{
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.basement (old: {
  patches =
    (old.patches or [])
    ++ [
      ./patches/basement/wasi-system.patch
      ./patches/basement/wasi-terminal-size.patch
    ];
})
