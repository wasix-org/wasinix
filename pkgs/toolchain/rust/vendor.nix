# Offline cargo registry for the wasix rust fork's multiple workspaces: vendor
# each workspace's lockfile with importCargoLock (uses the already-resolved
# entries, so no re-resolution of the [patch.crates-io] forks and no vendor-wide
# FOD hash) and emit one source-replacement config serving them all. (Stock rust
# ships this as the release tarball's vendor/; the fork ships only a git tag.)
#
# crates-io and git-fork sources (cc-rs, libc) must be vendored into SEPARATE
# directories: a cargo `directory` source is keyed by name+version alone, and
# cc 1.2.27 exists both as the git fork (src/bootstrap, adds the
# wasm32-wasmer-wasi-dl arm) and as stock crates-io (src/tools/cargo). One merged
# dir would silently serve one lockfile the other's crate under the wrong
# checksum. So each source is replaced with the directory holding its own crates.
#
# All derived from the lockfiles in pure Nix: fromTOML to classify by source,
# linkFarm for the trees, formats.toml for the config.
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

  # name-version to vendored-crate subpath for every package whose source matches
  # `pred`, unioned across all lockfiles. importCargoLock names each crate dir
  # "<name>-<version>"; workspace members carry no `source` and aren't vendored.
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

  # One [source."git+..."] entry per distinct git source, replaced with the git
  # vendor dir. The source id encodes url + ref + rev; parse them back out.
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
