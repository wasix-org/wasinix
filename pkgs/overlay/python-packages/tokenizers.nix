# tokenizers for wasix. maturin/pyo3 wheel (HF tokenizers; litellm token
# counting). pyo3 abi3 + extension-module are already in its default features.
# Needs: getrandom 0.3 routed to wasi_p1 (vendor patch, no fork); target-lexicon
# dl; and the esaxx-rs C++ suffix-array crate cross-compiled. esaxx-rs builds
# through cc-rs, which defaults C++ to -fno-exceptions and wins over env flags,
# but sais.hxx uses `try` -- so patch its build.rs to append -fexceptions +
# -fwasm-exceptions (cc-rs emits those last) so it compiles. The resulting legacy
# Wasm-EH (from esaxx's C++ and onig's setjmp) is translated to exnref by the
# shared maturin hook (set/rust-platform.nix), so no per-crate --wasm-use-legacy-eh
# is needed. CC/CXX are the wasix cc so the cc crate cross-compiles. No openssl
# (nixpkgs lists it but nothing in the crate graph links it).
{
  pyprev,
  final,
  helpers,
  ...
}: let
  rust = import ./lib/rust.nix {inherit final;};
  cc = "${final.stdenv.cc}/bin/${final.stdenv.cc.targetPrefix}cc";
  cxx = "${final.stdenv.cc}/bin/${final.stdenv.cc.targetPrefix}c++";
  # Two vendored-crate fixes, both refreshing .cargo-checksum.json:
  #  - esaxx-rs: sais.hxx uses `try`, but cc-rs defaults C++ to -fno-exceptions
  #    and the toolchain's -fwasm-exceptions doesn't reach this cc-rs invocation
  #    (PIC then errors "PIC without wasm exceptions"). Re-add -fexceptions +
  #    -fwasm-exceptions so it compiles.
  #  - pyo3-async-runtimes: tokio's rt-multi-thread is unsupported on wasm
  #    (compile_error), so drop it from its tokio features and build the runtime
  #    with new_current_thread(). tokenizers' sync token counting (all litellm
  #    needs) never runs the async runtime, so a single-thread runtime is fine.
  patchTokenizersVendor = cargoDeps:
    final.buildPackages.runCommand cargoDeps.name {jq = final.buildPackages.jq;} ''
      cp -rL ${cargoDeps} $out
      chmod -R +w $out
      refresh() { # <cratedir> <relpath>
        h=$(sha256sum "$1/$2" | cut -d' ' -f1)
        $jq/bin/jq --arg h "$h" --arg f "$2" '.files[$f]=$h' \
          "$1/.cargo-checksum.json" > "$1/.cargo-checksum.json.new"
        mv "$1/.cargo-checksum.json.new" "$1/.cargo-checksum.json"
      }
      d=$(find $out -maxdepth 2 -type d -name 'esaxx-rs-*' | head -1)
      [ -n "$d" ] || { echo "no vendored esaxx-rs to patch" >&2; exit 1; }
      grep -q '.flag("-std=c++11")' "$d/build.rs" \
        || { echo "esaxx-rs build.rs changed — update tokenizers.nix" >&2; exit 1; }
      sed -i 's/\.flag("-std=c++11")/.flag("-std=c++11").flag("-fexceptions").flag("-fwasm-exceptions")/g' "$d/build.rs"
      refresh "$d" build.rs

      p=$(find $out -maxdepth 2 -type d -name 'pyo3-async-runtimes-*' | head -1)
      [ -n "$p" ] || { echo "no vendored pyo3-async-runtimes to patch" >&2; exit 1; }
      grep -q 'Builder::new_multi_thread()' "$p/src/tokio.rs" \
        || { echo "pyo3-async-runtimes tokio.rs changed — update tokenizers.nix" >&2; exit 1; }
      sed -i 's/Builder::new_multi_thread()/Builder::new_current_thread()/' "$p/src/tokio.rs"
      sed -i '/^ *"rt-multi-thread",$/d' "$p/Cargo.toml"
      refresh "$p" src/tokio.rs
      refresh "$p" Cargo.toml
    '';
in
  helpers.libTweaks {
    # The cdylib's legacy libc++ Wasm-EH (esaxx-rs C++ throws) is translated to
    # exnref by the shared maturin hook (set/rust-platform.nix). See WASIX-TODO.md.
    # tokio only supports sync/macros/io-util/rt/time on wasm; the bindings ask
    # for rt-multi-thread + signal too (compile_error!). Sync tokenization (what
    # litellm needs for token counting) doesn't use the async runtime, so trim to
    # the wasm-supported subset. Features don't change the lock, so no re-vendor.
    postPatch = ''
      f=bindings/python/Cargo.toml
      [ -f "$f" ] || f=Cargo.toml
      substituteInPlace "$f" \
        --replace-fail 'features = ["rt", "rt-multi-thread", "macros", "signal"]' 'features = ["rt", "macros"]'
      # The bindings also build a global multi-thread runtime (for spawn_blocking);
      # switch to a current-thread one (rt-multi-thread is gone). The blocking pool
      # still works, and sync token counting doesn't drive the async scheduler.
      s=bindings/python/src/lib.rs
      [ -f "$s" ] || s=src/lib.rs
      substituteInPlace "$s" \
        --replace-fail 'Builder::new_multi_thread()' 'Builder::new_current_thread()'
    '';
    cargoDeps = cd:
      patchTokenizersVendor (rust.patchVendoredGetrandomWasi (rust.patchVendoredTargetLexiconDl cd));
    env = {
      PYO3_CROSS_LIB_DIR = rust.pyo3CrossLibDir;
      CC = cc;
      CXX = cxx;
      # onig_sys (oniguruma, C) builds PIC (needs wasm-EH) and uses setjmp/longjmp
      # (lowered to wasm SjLj `try`), so it needs -fwasm-exceptions to compile; the
      # legacy encoding is fine, the maturin hook translates the .so to exnref.
      CFLAGS = "-fwasm-exceptions";
    };
  }
  pyprev.tokenizers
