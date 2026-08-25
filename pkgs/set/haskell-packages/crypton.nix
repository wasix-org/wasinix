# crypton's argon2 C uses threads; disable (wasm is single-threaded).
{
  hprev,
  toolchain,
  ...
}:
toolchain.haskell.lib.appendConfigureFlags hprev.crypton ["--ghc-option=-optc-DARGON2_NO_THREADS"]
