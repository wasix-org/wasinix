# The nix evaluator for wasix: the `nix` CLI only, no build/sandbox support.
#
# nixpkgs builds nix as `nix-everything`, a merge of every component plus the
# manual, the C APIs and the test suites; we take its `nix-cli` passthru, which
# is the binary and the libraries it links (nix-util/store/fetchers/expr/
# flake/main/cmd). Building derivations never happens here: seccomp sandboxing
# and the sandbox shell are already off for a non-Linux host, and the evaluator
# reaches the store only to read and to add paths.
#
# Deviations from a native build, all forced by the target:
#   - GC off. Boehm GC finds roots by scanning the machine stack and registers,
#     neither of which a wasm host exposes. libexpr's own switch leaks instead,
#     which is what upstream already does on Windows and is fine for a
#     short-lived evaluator.
#   - Boost: see packages/boost.nix and the patches.
#   - Markdown help off: lowdown doesn't cross-build.
{
  final,
  prev,
  helpers,
  ...
}: let
  boostRoot = final.buildPackages.symlinkJoin {
    name = "boost-wasix-root";
    paths = [final.boost final.boost.dev];
  };

  # Meson's boost lookup ignores pkg-config and the BOOST_* env vars when
  # cross-compiling; a machine-file property is the only channel. Merged after
  # nixpkgs' own --cross-file.
  boostRootFile = final.buildPackages.writeText "boost-root-cross-file.ini" ''
    [properties]
    boost_root = '${boostRoot}'
  '';

  # overrideScope has to come before appendPatches: the other order dies in this
  # spliced cross scope with "expected a set but found a function", though the
  # same chain is fine in a plain nixpkgs cross set.
  configured = prev.nix.overrideScope (_: prevScope: {
    nix-expr = prevScope.nix-expr.override {enableGC = false;};
    nix-store = prevScope.nix-store.override {
      withAWS = false;
      # Derivation builds are unsupported, so their embedded builder shell is
      # unreachable from this evaluator-only package.
      embeddedSandboxShell = false;
    };
    # the repl keeps its default editline; readline's .pc wants a termcap we
    # don't have
    nix-cmd = prevScope.nix-cmd.override {enableMarkdown = false;};
  });

  patched = configured.appendPatches [
    ./patches/no-boost-iostreams-mmap-on-wasi.patch
    ./patches/boost-modules-available-on-wasi.patch
    ./patches/portability-32-bit-libcxx.patch
    ./patches/unsupported-posix-apis-on-wasi.patch
    ./patches/no-prelink-on-wasi.patch
  ];

  components = patched.overrideAllMesonComponents (_: prevAttrs: {
    mesonFlags = (prevAttrs.mesonFlags or []) ++ ["--cross-file=${boostRootFile}"];
    # Standing in for the prelink the patch above drops: every consumer of a
    # nix library must take all of its members, or the translation units that
    # only run a static registrar (primops, store implementations) are dropped
    # and the feature silently disappears. The .pc files are how the components
    # find each other, so the bracket goes there.
    # postFixup, not postInstall: multiple-outputs moves the .pc files from
    # $out to $dev during fixup.
    postFixup =
      (prevAttrs.postFixup or "")
      + ''
        for pc in "''${dev-$out}"/lib/pkgconfig/nix-*.pc; do
          [ -e "$pc" ] || continue
          sed -i -E 's|(-lnix[a-z0-9-]*)|-Wl,--whole-archive \1 -Wl,--no-whole-archive|g' "$pc"
        done
      '';
  });
in
  helpers.wasmRename {wasmName = "nix";} (helpers.libTweaks {
      passthru.wasix.shipped = true;
      passthru.wasix.updateNotes = [
        {message = "recheck the vendored WASI portability patches against the new Nix release";}
      ];
      # nixpkgs appends "+<n>" for the patches we add, which is not semver.
      # The patch count is a rebuild of the same upstream release, so it belongs
      # in the rel, not the version.
      passthru.wasmer.version = v: final.lib.head (final.lib.splitString "+" v);
      # C++ exceptions rule out the no-EH profile; PIC is untested.
      passthru.wasix.supportedProfiles =
        builtins.filter (p: builtins.elem p helpers.profiles.withoutPic) helpers.profiles.withEh;
      # wasmRename renames bin/nix after this hook. Keep Nix's compatibility
      # commands and build-remote entry point targeting the final name.
      postInstall = ''
        for alias in "$out"/bin/nix-*; do
          if [ -L "$alias" ] && [ "$(readlink "$alias")" = nix ]; then
            ln -sf nix.wasm "$alias"
          fi
        done
        if [ -L "$out/libexec/nix/build-remote" ]; then
          ln -sf ../../bin/nix.wasm "$out/libexec/nix/build-remote"
        fi
      '';
    }
    components.nix-cli)
