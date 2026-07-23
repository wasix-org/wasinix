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
scripts/spot.sh exnrefEh.zlib                        # toolchain experiment, no flags
scripts/spot.sh --dry-run exnrefEh.zlib              # what would it cost?
scripts/spot.sh --keep zlib exnrefEh.curl            # test a zlib edit through curl
scripts/spot.sh --local exnrefEh.zlib exnrefEh.git   # several targets, one splice, built here
```

A target is a dotted path into `nixpkgsByProfile`, written `<profile>.<attr>`
such as `exnrefEh.zlib`. There is nothing to author: edit whatever files you want
(a wasixcc patch, a sysroot flag, a package definition), name the attrs to build
from them, and everything else comes from the base revision. One caveat: the
splice reads the working tree as a flake, so a brand new file (a fresh `.patch`,
say) has to be `git add`ed first, or it is invisible and the target comes out
identical to base.

## The model

Everything comes from base. `--keep` names the attrs to take from your working
tree instead, and the targets are always kept. That is the whole idea: pick what
rebuilds, and the rest is the cache.

A kept attr is built from your edited definition, but its inputs (its linked
dependencies and its toolchain) still resolve to base, apart from any input you
also keep. So `--keep zlib` with target `curl` rebuilds curl and your zlib
against an otherwise base world.

## Choosing the cut with --keep

`--keep` is a small set expression. Its terms:

| term                      | meaning                                              |
| ------------------------- | ---------------------------------------------------- |
| `cc`, `rust`, `haskell`   | one toolchain: stdenv, rustPlatform, haskellPackages |
| `toolchain`               | all three toolchains, and the default                |
| `all`                     | every attr                                           |
| `none`                    | nothing extra, so only the targets                   |
| a package name, e.g. zlib | that package                                         |
| `-term`                   | remove `term` from what you named before it          |

You build up from what you add. A removal only pares down a base you named, so
`all,-rust` and `toolchain,-rust` are valid but `-rust` on its own is an error.
The default is `toolchain`, so a plain toolchain experiment needs no flags.

- `exnrefEh.zlib` with no flag keeps the toolchains, so a wasixcc, sysroot, rustc,
  or ghc edit reaches the target with nothing to configure.
- `--keep toolchain,zlib exnrefEh.curl` keeps the toolchains and a zlib edit, the
  "edit a common dependency, test one package" case.
- `--keep zlib exnrefEh.curl` keeps only zlib, so the toolchains come from base
  too; this isolates the zlib edit from any toolchain difference on your branch.
- `--keep toolchain,-rust exnrefEh.ripgrep` keeps the C and Haskell toolchains but
  takes rust from base, so ripgrep builds against the base rust toolchain.

An unknown name, or a keep of only removals, is an error, not a silent no-op.

## --base and cost

`--base` is the pristine revision everything pins to; it defaults to HEAD. Pick a
revision CI has actually built, because anything uncached there gets built too,
which is expensive and has nothing to do with your change.

A dry run prints two build counts. A count is how many derivations that side
would have to compile; cached ones download instead and do not count.

```text
spot: base rev   0 to build   (want 0; nonzero = --base not cached)
spot: this run   8 to build
```

`this run` is the experiment's cost: the targets rebuilt from your tree, plus any
kept dependency whose output your change moved. `base rev` checks `--base`; it is
the same targets built at the base commit, and should be 0, because a CI-built
base is entirely fetchable. A nonzero `base rev` means much of `this run` is just
rebuilding base, so pick a better revision.

The splice refuses to build when every target already equals base, since a change
that never reaches a target would look green while testing nothing.

## Several targets

Pass more than one target and they share a single splice, so one evaluation
serves them all. Each target's own attr is kept, so a co-tested target sees the
others on the working tree rather than from base. Building `zlib` and `curl`
together links curl against your `zlib`; building `curl` alone links it against
base `zlib`.

## --local

The build runs on the remote builder by default, because a toolchain experiment
rebuilds the compiler wrappers and pulls a large base closure. `--local` runs on
this machine instead, for when no remote builder is configured or the target is
cheap.

## How the pin is built

The splice lives in `pkgs/spot.nix` and pins in two layers, because a dependency
reaches a package by two routes.

1. The overlay fixpoint, for `final.<dep>` references. This is the convention for
   linked dependencies, and is out of reach of `.override`.
2. The target's own function arguments, for dependencies that are plain nixpkgs
   packages with no overlay entry (the shell tools a CLI reaches for, such as
   coreutils, gawk, or gnugrep). The fixpoint pin does not cover those, so
   without this layer a target like git would drag its whole tool closure onto
   the work toolchain. This layer pins only arguments that are themselves wasix
   builds, so a natively taken argument (an interpreter's `tzdata` or `bash`) is
   left alone rather than swapped for a wasm build.

Three constraints shape the fixpoint pin, each of which leaks packages into the
rebuild if ignored.

- It covers the overlay's package names plus the three toolchain attrs (stdenv,
  rustPlatform, haskellPackages), which enter outside those names (stdenv via
  `replaceCrossStdenv`, the other two as overlay attrs) and so must be listed to
  be reachable. It does not cover the whole set: blanket-pinning every attr trips
  nixpkgs' stdenv bootstrap assertions, because the lower bootstrap stages read
  attrs out of the same fixpoint. Pinning `final.stdenv` alone is safe, since the
  bootstrap does not read it back.
- It is guarded on `isWasix`. An overlay applies to every stage, and these names
  are cross builds, so replacing them in `buildPackages` would swap native build
  tools for wasm ones and pull in a native bootstrap.
- It is injected through `pkgs/default.nix` (the `spotOverlays` argument) rather
  than by extending one set from outside, because profile sets reference each
  other through `preferredProfilePackages`; pinning one profile alone still leaks
  the runtime-invoked dependencies that resolve in another.

`spotOverlays` is empty in every normal evaluation, and the seam moves no drv
path. Nothing that ships may set it.

## Nested python targets

`exnrefEhpic.python314.pkgs.numpy` is a valid target, and the interpreter stays
pinned. A python extension's compiler comes from `buildPythonPackage`, which
takes it from the interpreter's passthru (nixpkgs `python-packages-base.nix`), so
it is reachable neither through the package's own `stdenv` argument (inert) nor
through the scope's `stdenv`. The splice overrides `buildPythonPackage` with one
built against the working-tree stdenv, which moves the wheel and nothing else:
the interpreter, hooks, and python dependencies all stay on base.

Two cases fall back to rebuilding the interpreter, still correct but larger: a
base revision whose `buildPythonPackage` has no `.override`, and a target kept
with `--keep python314`, which is how you test an edit to the interpreter's own
definition, since the pinned base scope would not have it.

## Limits

- The output mixes objects built by two toolchains. A green spot build is
  evidence that a change compiles and links, not proof that it is correct. Verify
  at the root before keeping the change.
- Never a CI job. `spot.nix` is deliberately not a flake output, because the base
  revision is an evaluation-time input.
- Targets are cross-set attrs. The layers above them (webc, `passthru.tests`, the
  python registry) are not spliced.
