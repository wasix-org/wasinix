# Updating pins

```sh
wasinix update --all                        # everything
wasinix update list                         # targets + current pins
wasinix update llvm wasix-libc              # named targets
wasinix update wasix-libc@2026-08-01.1      # a specific release
wasinix update wasmer@rev:<40-hex>          # a specific revision
wasinix update --all --pr                   # commit, push, open the PRs
```

`TARGET@VERSION`, `TARGET@tag:NAME` and `TARGET@rev:SHA` are the whole request
grammar, shared with `build --with` and `bisect --good/--bad`. A version is
whatever the target's own update script resolves; a tag is looked up in the
target's remote and pinned as the commit it names, so a repository that tags
`v1.2.3` needs `tag:v1.2.3` and one that tags `1.2.3` needs `tag:1.2.3`. A
target that does not accept the mode you asked for says so; `cargo-registry`
re-resolves the crate pins.

How a pin bumps is declared next to it (`passthru.updateScript`, the standard
nixpkgs convention); its constraints and quirks are comments in the same file. A
derived pin is recalculated by the package's `updateScript`, so the bump is
declared once. For example, `pkgs/products/wasix-rust/update.sh` recalculates
the stage0 bootstrap pin after moving the Rust source pin.

A script's tools come from its own declaration, not an ambient environment: the
command is a `writeShellApplication` wrapper naming its `runtimeInputs` and
re-entering the checkout's script (`pkgs/products/cargo-registry/package.nix` is
the model). The declaration must interpolate the wrapper
(`"${wrapper}/bin/..."`): the interpolation puts the wrapper's drv path in the
string context the flake collects, and the driver realises those derivations on
demand. The one ambient tool is `wasinix` itself, on the script's PATH so it
talks back to the driver that invoked it: `wasinix update request` prints the
driver's release/revision request (`--expect NAME` guards the target), and
`wasinix update nix-update -- <argv>` runs a declared nix-update command with
that request applied.

`wasinix update` is only the driver: flake-input targets, per-target isolation,
the repo-wide steps a bump implies, and one ChangeSet describing everything that
moved. Every mutation renders from that ChangeSet: the terminal receipt, the
commit messages (`<target>: <old> -> <new>`), the PR title, and the PR body, so
a PR and its CI comment agree by construction. The repo-wide steps are
registry-history retention (keep the outgoing version rebuildable when a bump
crosses a major, or per `passthru.wasix.retention`: `minor` for
latest-per-minor, `none` to opt out), the rels.json prune (drop keys nothing
serves), and finally the `passthru.wasix.postUpdateHook`s, which re-sync state
derived from pins. Hooks run only when their package version changes and receive
the old and new versions as their final two arguments. `wasinix update hooks`
runs every hook without version arguments to request an unconditional repair.

History retention and rel pruning run after every changed target because each
can move a served version. Retention fetches and hashes the outgoing release, so
a bump may do network work beyond the pins themselves; see
[Registry history](registry.md#registry-history). The `update.yml` workflow runs
weekly, one PR per moved target (`auto/update-<target>`), each opened by
`wasinix update <target> --pr`; a manual dispatch with `only` selects targets.

Update PRs the bot opens are managed: the PR body records the recipe that
generated the branch and the head the bot last wrote (a
`<!-- wasinix:changeset ... -->` marker). Commenting `/wasinix update` on a
managed PR replays its recipe; `/wasinix update <targets>` or
`/wasinix versions bump <specs|--changed>` runs as spelled on any same-repo PR.
Pushing your own commits pauses automated refreshes, and the bot replies with
the intervening commits instead of replacing them; `/wasinix regenerate --force`
discards the branch and rebuilds it from the recipe. The mutation runs in a job
with no push credential (the PR tree's own update scripts execute there); a
second job re-verifies the bundle and pushes with a lease. `ci-command.yml`
carries the split; the `UPDATE_PR_TOKEN` secret makes pushed heads trigger CI.

The served-version tables are maintained under the `versions` noun:
`versions add <package>@<version>` (or `--per-major`/`--per-minor` in bulk)
backfills registry history, `versions import <lockfile>` pins what a lockfile
declares, and `versions bump <package>` bumps a publication release counter.

Things to check on a bump are declared as `passthru.wasix.updateNotes`
(`pkgs/lib/default.nix`) and surface in the PR body. Toolchain and nixpkgs bumps
rebuild the world.

A note is the last resort, for a drift nothing catches. Before writing one, ask
what the bump does when the thing it warns about happens: a vendored patch whose
context moved fails to apply, a renamed attribute fails to evaluate, a changed
interface fails to build or fails a test. Those need no note, and a note that
repeats them is noise a reader has to re-derive.

Where nothing fails, make something fail instead. A patch that only adds a
fallback stays silently inert once upstream supplies the real thing, so give it
a guard that errors when the fallback is no longer needed; a value copied from
upstream gets a test that compares the two. Write the note only when the drift
is genuinely invisible to the build.
