# wasix-crate-patches

The wasix edits for upstream Rust crates, applied at vendor time by
`patchVendor` (set/rust-platform.nix) and republished by the cargo-registry
mint. Both resolve the same spec through `crate-edits.nix`, so an edit is
defined once. Packages stay plain `buildRustPackage { cargoHash = ...; }`; the
edits are baked into the vendored sources before `cargo build` sees them.

## Layout

```
<crate>/edits.nix        the spec (below)
<crate>/<version>.patch  floor patches, named by the version authored against
rewriters/<name>.nix     reusable source rewriters, one script drv each
```

## `edits.nix`

```nix
{ lib, rewriters, adds }: {
  edited     = [ ">=1.0.3" ];            # versions we patch (floored)
  stock      = [ ">=1.2.2" ];            # optional: versions known good unpatched
  notMinted  = null;                     # optional reason to skip the registry
  forVersion = { version, floorPatch }: {
    patches    = [ ./thread-id.patch ] ++ lib.optional (floorPatch != null) floorPatch;
    patchPhase = ''${rewriters.wasmerAsNative}'';
    adds       = [ adds.wasix ];
  };
}
```

Each resolved version of an edited crate is `edited`, `stock`, or `unsupported`;
the last hard-fails the vendor, so a version drifting past its coverage surfaces
loudly instead of miscompiling downstream.

- `edited` (constant): the versions we patch, a semver constraint (comparator
  terms `>= <= < > =`, comma-AND per element, the array OR-ed). Prefer an
  open-ended floor range (`>=X`): `floorFor` applies the highest `<version>.patch`
  at or below the resolved version, and a version the patch no longer fits
  hard-fails for a fresh patch. It is the coverage the vendor patches and the
  registry publishes.
- `stock` (constant, optional): versions deliberately left as upstream ships
  them. Set it only for versions known good unpatched: a durable upstream fix (a
  boundary like `>=0.6.3`), or one you have built green. Never an optimistic
  range.
- `notMinted` (constant): keep a crate off the registry (git-sourced libdd,
  vendor-only rewrites) with a reason.
- `forVersion`: per-version, may branch on `version`. `patches` is the stack
  (residuals prepend, the engine-selected `floorPatch` last; all compose).
  `patchPhase` is postPatch shell that runs the `rewriters` drvs. `adds` are deps
  the edit pulls in that upstream lacks (declared once in `adds.nix`).

A crate with only `<version>.patch` files needs just `{ edited = [...]; }`.

## Rewriters

`rewriters/<name>.nix` is a script derivation run against the crate dir (`$PWD`),
failing loud if its target or expected source shape is gone. A `patchPhase` runs
one by interpolating its store path (`${rewriters.wasmerAsNative}`), so editing
a rewriter rebuilds only the crates that use it and adding one rebuilds nothing.

Large files that are mostly stable across releases can live next to the crate's
`edits.nix` and be copied explicitly from its `patchPhase`. Keep only upstream
integration hunks in floor patches, and overlay payload variants at explicit
API boundaries from that phase.
