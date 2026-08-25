# wasm has no threaded RTS (libHSrts_thr); drop -threaded from the CLI exe.
{
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.djot (old: {
  patches = (old.patches or []) ++ [./patches/djot/wasi-no-threaded.patch];
})
