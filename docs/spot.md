# Spot-override

Rebuild one or more attrs against your working tree while everything below them
comes from a cached base revision, so a change whose honest rebuild is the whole
world costs only the attrs you name. It suits toolchain and low-level dependency
experiments, where the change is a line or two but rebuilding to check it is
enormous.

It is not for shipping. The output mixes objects built by two toolchains, so a
green spot build is evidence that a change compiles and links, not proof that it
is correct. Verify at the root, on the full build, before keeping a change.

```sh
wasinix spot packages.wasix.exnrefEh.zlib             # toolchain experiment
wasinix spot packages.wasix.exnrefEh.zlib --plan      # what would it cost?
wasinix spot packages.wasix.exnrefEh.curl \
  --from-source packages.wasix.zlib                   # test a zlib edit through curl
wasinix spot packages.wasix.exnrefEh.zlib --on local  # build here, not on a remote
```

Targets and `--from-source` are CI selectors resolved through the selector
catalog, and `--on` is the placement axis every expensive verb takes. With no
`--from-source`, spot takes the toolchain from your working tree and everything
else from base; `--target-only` narrows that to just the named targets. A
lower-level dev interface, `nix build -f spot.nix`, takes the resolved `keep`
list of package and toolchain names directly.

A resolved target is written `<profile>.<package>`, such as `exnrefEh.zlib`.
There is nothing to author: edit whatever files you want (a wasixcc patch, a
sysroot flag, a package definition), name the attrs to build from them, and
everything else comes from the base revision. One caveat: the splice reads the
working tree as a flake, so a brand new file (a fresh `.patch`, say) has to be
`git add`ed first, or it is invisible and the target comes out identical to
base.

## The model

Everything comes from base. The keep set names the attrs taken from your working
tree instead, and the targets are always kept. That is the whole idea: pick what
rebuilds, and the rest is the cache.

A kept attr is built from your edited definition, but its inputs (its linked
dependencies and its toolchain) still resolve to base, apart from any input also
kept. So keeping `zlib` with target `curl` rebuilds curl and your zlib against
an otherwise base world.

## Choosing the cut with --from-source

`--from-source` names CI selectors whose spot owners join the keep set
(repeatable):

| selector                                       | keeps                                                       |
| ---------------------------------------------- | ----------------------------------------------------------- |
| `toolchain`                                    | all three toolchains: stdenv, rustPlatform, haskellPackages |
| `cc`                                           | stdenv only                                                 |
| `rust`                                         | rustPlatform only                                           |
| `haskell`                                      | haskellPackages only                                        |
| a package selector, e.g. `packages.wasix.zlib` | that package                                                |

The default is `toolchain`, so a plain toolchain experiment needs no flags;
`--target-only` keeps nothing beyond the targets themselves, isolating a package
edit from any toolchain difference on your branch.

- `exnrefEh.zlib` with no flag keeps the toolchains, so a wasixcc, sysroot,
  rustc, or ghc edit reaches the target with nothing to configure.
- `--from-source packages.wasix.zlib exnrefEh.curl` keeps a zlib edit, the "edit
  a common dependency, test one package" case.
- `--from-source rust exnrefEh.ripgrep` keeps only the rust toolchain, so a
  rustc change is tested against the base C world.

An unknown selector is an error, not a silent no-op.

## --base and cost

`--base` is the pristine revision everything pins to; it defaults to HEAD. Pick
a revision CI has actually built, because anything uncached there gets built
too, which is expensive and has nothing to do with your change.

A dry run prints two build counts. A count is how many derivations that side
would have to compile; cached ones download instead and do not count.

```text
spot base rev: 0 to build (want 0; nonzero = --base not cached)
spot this run: 8 to build
```

`this run` is the experiment's cost: the targets rebuilt from your tree, plus
any kept dependency whose output your change moved. `base rev` checks `--base`;
it is the same targets built at the base commit, and should be 0, because a
CI-built base is entirely fetchable. A nonzero `base rev` means much of
`this run` is just rebuilding base, so pick a better revision.

The splice refuses to build when every target already equals base, since a
change that never reaches a target would look green while testing nothing.

## Several targets

Pass more than one target and they share a single splice, so one evaluation
serves them all. Each target's own attr is kept, so a co-tested target sees the
others on the working tree rather than from base. Building `zlib` and `curl`
together links curl against your `zlib`; building `curl` alone links it against
base `zlib`.

## Placement

The build runs on the configured remote by default (`--on <remote>` or
`--on <remote>:store` picks one explicitly), because a toolchain experiment
rebuilds the compiler wrappers and pulls a large base closure. `--on local` runs
on this machine instead, for when no remote builder is configured or the target
is cheap. A host-routed placement refuses `--plan`, since the probe would price
a different world than the host builds.

## How the pin is built

The splice in the root `spot.nix` reads the base project's raw WASIX package
sets, constructs a fresh working-tree project, and appends one pinning overlay
through the caller-owned `importNixpkgs`. For each profile, that overlay
replaces every cataloged package and toolchain owner not in the keep set with
its base derivation. Dependencies reached through `packages.sameProfile`
therefore see the same pinned fixpoint as direct package arguments.

The overlay applies only to WASIX sets. It does not pin the complete nixpkgs
set, which would interfere with stdenv bootstrap, and it is supplied only to the
temporary project created by Spot, so normal project evaluation has no Spot
seam.

## Limits

- Never a CI job. `spot.nix` is deliberately not a flake output, because the
  base revision is an evaluation-time input.
- Targets are cataloged WASIX packages. Artifacts, tests, and nested Python
  packages are not direct Spot targets.
