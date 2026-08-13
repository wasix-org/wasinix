# Updating pins

```sh
nix run .#scripts.update                    # everything
nix run .#scripts.update -- --list          # targets + current pins
nix run .#scripts.update -- --only llvm wasix-libc
```

How a pin bumps is declared next to it (`passthru.updateScript`, the standard
nixpkgs convention); its constraints and quirks are comments in the same file. A
derived pin is recalculated by the package's `updateScript`, so the bump is
declared once. For example, `pkgs/toolchain/rust/update.py` recalculates the
bootstrap and vendor inputs after moving the Rust source pin.

`scripts/update.py` is only the driver: flake-input targets, per-target
isolation, the repo-wide steps a bump implies, and the summary. Those are
registry-history retention (keep the outgoing version rebuildable when a bump
crosses a major, or per `passthru.wasix.retention`: `minor` for
latest-per-minor, `none` to opt out), the rels.json prune (drop keys nothing
serves), and finally the `passthru.wasix.retentionHook`s, which re-sync listings
derived from pins. Hooks that would repeat expensive work on unrelated bumps
must gate themselves.

These steps run in order for every target because each can move a served
version. Retention fetches and hashes the outgoing release, so a bump may do
network work beyond the pins themselves; see
[Registry history](registry.md#registry-history). The `update.yml` workflow runs
weekly with one PR per moved target; a manual dispatch with `only` bundles
targets into one PR.

Things to check on a bump are declared as `passthru.wasix.updateNotes`
(`pkgs/lib/default.nix`) and surface in the PR body. Toolchain and nixpkgs bumps
rebuild the world.
