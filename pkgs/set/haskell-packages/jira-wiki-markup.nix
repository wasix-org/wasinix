# wasm has no threaded RTS (libHSrts_thr); drop -threaded from the CLI exe.
{
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.overrideCabal hprev.jira-wiki-markup (old: {
  patches = (old.patches or []) ++ [./patches/jira-wiki-markup/wasi-no-threaded.patch];
})
