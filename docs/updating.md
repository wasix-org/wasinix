# Updating pins

```sh
nix run .#scripts.update                    # everything
nix run .#scripts.update -- --list          # targets + current pins
nix run .#scripts.update -- --only llvm wasix-libc
```

How a pin bumps is declared next to it (`passthru.updateScript`, the standard
nixpkgs convention); its constraints and quirks are comments in the same file.
That includes a pin _derived_ from another pin: the rust fork's stage0
bootstrap and cargo vendor hash, and wasix-libc's witx submodules are
re-derived by `pkgs/toolchain/rust/update.py` and
`pkgs/toolchain/sysroot/update.py`, which the package's `updateScript` runs
after its own bump (the `nix-update-script` command is passed through as their
argv, so the bump is declared once).

`scripts/update.py` is only the driver: flake-input targets, per-target
isolation, the repo-wide steps a bump implies, and the summary. Those are
registry-history retention (keep the outgoing version rebuildable when a bump
crosses a major, or per `passthru.wasix.retention`: `minor` for
latest-per-minor, `none` to opt out), the rels.json prune (drop keys nothing
serves), and finally the `passthru.wasix.retentionHook`s: a per-package command
that re-syncs a listing derived from the pins (icu regenerates its
`versions.nix` from the nixpkgs majors, so a dropped or added major tracks
automatically). They run in that order, for every target rather than any one of
them, because either can move a served version. Retention fetches and hashes the
outgoing release, so a bump run can do network work beyond the pins themselves
(see "Registry history" in `docs/packaging.md`). The `update.yml` workflow runs
it weekly with one PR per moved target; a manual dispatch with `only` bundles
targets into one combined PR.
Things to check on a bump are declared as `passthru.wasix.updateNotes`
(`pkgs/lib/default.nix`) and surface in the PR body. Toolchain and nixpkgs
bumps rebuild the world.
