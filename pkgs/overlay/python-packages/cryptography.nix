# maturin/pyo3 wheel with a `cc`-crate OpenSSL shim. CC is the wasix cc so the shim
# cross-compiles; OPENSSL_NO_VENDOR links our cross openssl; CFLAGS=-fwasm-exceptions
# (ehpic PIC needs wasm-EH); plus the shared maturin/pyo3 wiring (see lib/rust.nix).
#
# The archive link leaves ~1000 openssl symbols as dylib imports (import-dynamic
# swallows the unresolved tail). Since the python main module exports its own static
# libcrypto (_ssl/_hashlib), those imports bind to python's copy and _rust straddles
# two half-initialized libcryptos: the default provider fails init when python's copy
# initialized first (hashlib before cryptography). Whole-archive libssl+libcrypto into
# the dylib so every openssl reference resolves inside.
{
  pyprev,
  pyfinal,
  final,
  helpers,
  ...
}: let
  lib = final.lib;
  # nixpkgs' patches target the release nixpkgs packages (right now the argon2
  # and scrypt test files); on a rebased history version they mis-apply, and
  # tests don't run cross anyway. Keyed on the history spec rather than a
  # version boundary so it stays right across nixpkgs bumps.
  isHistory = (pyprev.cryptography.passthru.wasix.historySpec or null) != null;
  # the rust crate and its lock sat under src/rust until 45 moved both to the
  # repo root; the setup hook validates $cargoRoot/Cargo.lock. The vendor reads
  # the same lock, from the history entry's vendorLayout.
  splitCargoRoot = lib.versionOlder pyprev.cryptography.version "45";
in
  helpers.libTweaks ({
      env = {
        CC = "${final.stdenv.cc}/bin/${final.stdenv.cc.targetPrefix}cc";
        OPENSSL_NO_VENDOR = "1";
        CFLAGS = "-fwasm-exceptions";
        # The extension links through rustc's own wasm rust-lld, which keeps
        # -C link-arg order, so the --whole-archive bracketing survives.
        # -Bsymbolic binds the included definitions locally instead of the main
        # module's exports.
        RUSTFLAGS = toString [
          "-C link-arg=-Bsymbolic"
          "-C link-arg=--whole-archive"
          "-C link-arg=${lib.getLib final.openssl}/lib/libssl.a"
          "-C link-arg=${lib.getLib final.openssl}/lib/libcrypto.a"
          "-C link-arg=--no-whole-archive"
          # openssl-sys's own -lssl/-lcrypto lazily pull some of the same
          # members; first definition wins and both are the same objects.
          "-C link-arg=--allow-multiple-definition"
        ];
      };
      maturinBuildFlags = ["--features" "pyo3/extension-module"];
      # cryptography-vectors does not cross-evaluate. The package-specific
      # OpenSSL checks and import smoke cover the extension.
      passthru.wasix.installCheck = false;
    }
    // lib.optionalAttrs isHistory {patches = _: [];}
    // lib.optionalAttrs splitCargoRoot {cargoRoot = "src/rust";})
  pyprev.cryptography
