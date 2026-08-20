# libgit2 for wasix (nix-fetchers links it for builtins.fetchGit).
# libssh2 doesn't cross-build (inet_addr is absent from wasix-libc), and the
# ssh transport is unreachable from wasm anyway; HTTPS via openssl stays on.
{
  prev,
  helpers,
  ...
}: let
  # The git2 CLI links util/process.c, which needs fork; Wasm-EH hides fork
  # (WASIX-TODO.md), so build the CLI only in the off profile, as upstream does.
  offProfile = (helpers.profileOf prev.stdenv.hostPlatform) == "off";
in
  helpers.extendPackage prev.libgit2 (
    {
      # appended after nixpkgs' flags; for duplicated -D options the last wins
      cmakeFlags = [
        "-DUSE_SSH=OFF"
        # `all` links the test binary, which needs mkfifo; cross can't run it anyway
        "-DBUILD_TESTS=OFF"
        # off only (see offProfile); nix links libgit2.a, never the CLI.
        "-DBUILD_CLI=${
          if offProfile
          then "ON"
          else "OFF"
        }"
      ];
      # BUILD_TESTS=OFF above means no libgit2_tests binary is ever built
      # (see comment there: cross can't run it anyway). doCheck=false stops
      # a check job from being generated for it at all; wasixCheckPrebuild
      # additionally stops the check-output wrapper's own build-time
      # snapshot from attempting a prebuild, since doCheck composes after
      # that wrapper reads old.doCheck and is invisible to it.
      doCheck = false;
      wasixCheckPrebuild = ":";
    }
    // helpers.linkInputs (helpers.dropInputsByName ["libssh2"])
  )
