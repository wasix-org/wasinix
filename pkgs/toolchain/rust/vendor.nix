# Offline cargo registry for a multi-workspace source tree (the wasix rust fork):
# given the workspaces' lockfiles, vendor every dependency and produce the
# source-replacement cargo config that serves them all. Stock rust ships this
# prebuilt as the release tarball's vendor/; the fork ships only a git tag, so we
# reconstruct it.
#
# Each workspace has its own lockfile, so each is vendored with importCargoLock
# (reads the already-resolved entries — no re-resolution of the [patch.crates-io]
# forks, no vendor-wide FOD hash) and one config hands the union to all of them.
#
# The crates come from two source kinds: crates-io and git forks (for the rust
# fork: cc-rs, libc). name+version is NOT unique across them — cc 1.2.27 is the
# dl-arm fork (the git pin that teaches cc-rs the `wasm32-wasmer-wasi-dl` ABI) in
# src/bootstrap but stock crates-io in src/tools/cargo. cargo keeps git+… and
# registry+… as distinct sources, each with its own checksum, so this is legal —
# but a `directory` source is keyed by name+version alone. Collapsing both into
# one vendored dir would force a single cc-1.2.27 and silently serve one lockfile
# the other's crate (e.g. cargo compiling fork code under stock's `d487aa…`
# checksum). So vendor the two source kinds into separate directories and replace
# each source with the directory holding ITS crates: every crate served from
# exactly the source its lockfile names.
#
# It's all derived from the lockfiles in Nix — fromTOML to classify by source,
# linkFarm for the trees (attrset keys dedupe across lockfiles; same
# source+version is identical content), formats.toml to serialise the config. No
# shell.
{
  lib,
  rustPlatform,
  linkFarm,
  formats,
}:
# The list of Cargo.lock paths (strings/paths into the source tree).
lockFiles: let
  # Git-pinned forks are pinned by commit, so builtins.fetchGit is pure.
  vendorOf = lf:
    rustPlatform.importCargoLock {
      lockFile = lf;
      allowBuiltinFetchGit = true;
    };
  packagesOf = lf: (builtins.fromTOML (builtins.readFile lf)).package or [];
  isGitSource = source: lib.hasPrefix "git+" source;

  # name-version → its vendored-crate subpath, for every package whose source
  # matches `pred`, unioned across all lockfiles. importCargoLock names each
  # crate dir "<name>-<version>"; workspace members carry no `source` and aren't
  # vendored.
  vendorTree = pred:
    lib.listToAttrs (lib.concatMap (
        lf: let
          v = vendorOf lf;
        in
          map (p: lib.nameValuePair "${p.name}-${p.version}" "${v}/${p.name}-${p.version}")
          (lib.filter (p: (p ? source) && pred p.source) (packagesOf lf))
      )
      lockFiles);

  cratesIoVendor = linkFarm "wasix-rust-vendor" (vendorTree (s: !isGitSource s));
  gitVendor = linkFarm "wasix-rust-vendor-git" (vendorTree isGitSource);

  # One [source."git+…"] entry per distinct git source: define it (cargo needs
  # the git url + ref to identify the source) and replace it with the git vendor
  # dir. The source id encodes url + ref + rev, so we read those back out of it.
  gitSourceEntry = source: let
    m = builtins.match ''git\+([^?#]+)(\?(rev|tag|branch)=([^#]+))?#(.+)'' source;
    refKind = lib.elemAt m 2;
  in
    lib.nameValuePair source ({
        git = lib.elemAt m 0;
        replace-with = "vendored-git";
      }
      // (
        if refKind != null
        then {${refKind} = lib.elemAt m 3;}
        else {rev = lib.elemAt m 4;}
      ));
  gitSources = lib.unique (lib.concatMap (
      lf: map (p: p.source) (lib.filter (p: (p ? source) && isGitSource p.source) (packagesOf lf))
    )
    lockFiles);

  cargoConfig = (formats.toml {}).generate "wasix-rust-cargo-config.toml" {
    source =
      {
        crates-io.replace-with = "vendored-sources";
        vendored-sources.directory = "${cratesIoVendor}";
        vendored-git.directory = "${gitVendor}";
      }
      // lib.listToAttrs (map gitSourceEntry gitSources);
  };
in {
  inherit cratesIoVendor gitVendor cargoConfig;
}
