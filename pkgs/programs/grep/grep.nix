{ lib, stdenv, toolchain, gnugrep, ... }:
(gnugrep.override {
  # WASIX build currently fails with PCRE2 in this toolchain/sysroot combo.
  # Grep still works for BRE/ERE/fixed-string modes, which is sufficient for
  # the base package; --perl-regexp is explicitly disabled below.
  pcre2 = null;
  # Prevent pulling a target-side runtime shell package into the WASIX build
  # closure. Grep itself does not need bash for normal operation here.
  runtimeShellPackage = null;
}).overrideAttrs (old: {
  # Upstream gnugrep runs gnulib-tests during build; several tests are not
  # portable to current WASIX and fail at compile-time. We only strip the
  # gnulib-tests subdir for WASIX, matching the portability strategy used
  # by nixpkgs on other constrained targets.
  postPatch = (lib.optionalString (old.postPatch != null) old.postPatch) + lib.optionalString stdenv.hostPlatform.isWasi ''
    sed -i 's:gnulib-tests::g' Makefile.in
  '';
  # Force the package to compile with wasixcc/wasix++ and related binutils.
  preConfigure = (old.preConfigure or "") + ''
    ${toolchain.commonPreConfigure}
  '';
  configureFlags = (old.configureFlags or [ ]) ++ [
    # Cross-target triple for this repository's WASIX toolchain.
    "--host=${toolchain.host}"
    # Matches the pcre2=null override above; avoids building unsupported
    # Perl-compatible regex path on this target.
    "--disable-perl-regexp"
  ];
  # Local compatibility patches:
  # - avoid opendirat symbol clash with WASIX libc
  # - treat stdin lseek permission behavior as non-seekable stream
  # - provide stable program name fallback when runtime argv/progname is empty
  patches = (old.patches or [ ]) ++ [
    ./patches/0001-opendirat-rename-for-wasix-libc-collision.patch
    ./patches/0002a-stdin-lseek-permission-as-nonseekable.patch
    ./patches/0003a-fallback-progname-when-runtime-argv0-is-missing.patch
  ];
  # Keep hardening off for this cross target to avoid toolchain-side
  # incompatibilities (same approach used by other WASIX packages here).
  hardeningDisable = [ "all" ];
  postInstall = (lib.optionalString (old.postInstall != null) old.postInstall) + ''
    # Convention in this repo: install program wasm binaries as *.wasm so the
    # aggregate `allWasm` target can discover and collect them from $out/bin.
    if [ -f "$out/bin/grep" ]; then
      mv "$out/bin/grep" "$out/bin/grep.wasm"
    fi
  '';
})
