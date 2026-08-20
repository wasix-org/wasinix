# tokenizers for wasix. maturin/pyo3 wheel (HF tokenizers; litellm token counting).
# pyo3 abi3 + extension-module are in its default features. Vendored-crate wasix
# fixes (getrandom, target-lexicon, esaxx-rs, pyo3-async-runtimes) are tree patches.
# The legacy Wasm-EH from esaxx's C++ / onig's setjmp is translated to exnref by the
# maturin hook. CC/CXX are the wasix cc so the cc crates cross-compile.
{
  pyprev,
  final,
  helpers,
  ...
}: let
  cc = final.lib.getExe' final.stdenv.cc "${final.stdenv.cc.targetPrefix}cc";
  cxx = final.lib.getExe' final.stdenv.cc "${final.stdenv.cc.targetPrefix}c++";
in
  helpers.libTweaks {
    # tokio's rt-multi-thread + signal are unsupported on wasm (compile_error!); sync
    # tokenization doesn't need the async runtime, so trim the bindings' tokio features
    # and switch to a current-thread runtime. The bindings are the wheel's own source
    # (not a vendored crate), so this is a postPatch; features don't change the lock.
    postPatch = ''
      f=bindings/python/Cargo.toml
      [ -f "$f" ] || f=Cargo.toml
      substituteInPlace "$f" \
        --replace-fail 'features = ["rt", "rt-multi-thread", "macros", "signal"]' 'features = ["rt", "macros"]'
      s=bindings/python/src/lib.rs
      [ -f "$s" ] || s=src/lib.rs
      substituteInPlace "$s" \
        --replace-fail 'Builder::new_multi_thread()' 'Builder::new_current_thread()'
    '';
    env = {
      CC = cc;
      CXX = cxx;
      # onig_sys (oniguruma, C) builds PIC (needs wasm-EH) and uses setjmp/longjmp
      # (lowered to wasm SjLj `try`), so it needs -fwasm-exceptions to compile; the
      # legacy encoding is fine, the maturin hook translates the .so to exnref.
      CFLAGS = "-fwasm-exceptions";
    };
    # No suite: every meaningful test file imports datasets (whose pyarrow
    # kills the session) or trains via fork-based multiprocessing.
    passthru = old:
      old
      // {
        wasix = (old.wasix or {}) // {installCheck = false;};
      };
  }
  pyprev.tokenizers
