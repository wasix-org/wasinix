# Updating pins

```sh
nix run .#scripts.update                    # everything
nix run .#scripts.update -- --list          # targets + current pins
nix run .#scripts.update -- --only llvm wasix-libc
```

How a pin bumps is declared next to it (`passthru.updateScript`, the standard
nixpkgs convention); its constraints and quirks are comments in the same file.
`scripts/update.py` is only the driver: flake-input targets, per-target
isolation, derived-file regen hooks (rust bootstrap, witx pins, rels.json,
registry history), the summary. The history hook fetches and hashes the
outgoing release when a nixpkgs bump crosses a major, so a bump run can do
network work beyond the pins themselves (see "Registry history" in
`docs/packaging.md`). The `update.yml` workflow runs it weekly with one PR per moved
target; a manual dispatch with `only` bundles targets into one combined PR.
Things to check on a bump are declared as `passthru.wasix.updateNotes`
(`pkgs/lib/default.nix`) and surface in the PR body. Toolchain and nixpkgs
bumps rebuild the world.
