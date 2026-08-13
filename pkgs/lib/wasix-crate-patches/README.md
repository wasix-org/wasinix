# wasix-crate-patches

Crate edits applied at vendor time and published by the cargo registry. Both
paths read `edits.nix` through `crate-edits.nix`, so each edit is defined once.

## Layout

```text
<crate>/edits.nix        edit specification
<crate>/<version>.patch  floor patch authored against that version
helpers.nix              patchPhase helpers
rewriters/<name>.nix     reusable source rewriters
```

## `edits.nix`

```nix
{ lib, helpers, rewriters, adds }: {
  edited = [ ">=1.0.3" ];
  stock = [ ">=1.2.2" ];
  notMinted = null;
  forVersion = { version, floorPatch }: {
    patches = [ ./thread-id.patch ]
      ++ lib.optional (floorPatch != null) floorPatch;
    patchPhase = ''${rewriters.wasmerAsNative}'';
    adds = [ adds.wasix ];
  };
}
```

| field        | meaning                                                                                                               |
| ------------ | --------------------------------------------------------------------------------------------------------------------- |
| `edited`     | Patched version ranges. Prefer an open floor such as `>=1.0.3`; the highest applicable `<version>.patch` is selected. |
| `stock`      | Optional ranges verified to work without edits.                                                                       |
| `notMinted`  | Optional reason the crate is not published.                                                                           |
| `forVersion` | Per-version patches, rewrite phase, and dependencies absent upstream.                                                 |

Ranges use semver comparators, comma-separated AND terms, and one OR branch per
list element. A resolved version outside both `edited` and `stock` fails. A
crate needing only floor patches can use `{ edited = [ ">=1.0.3" ]; }`.

## Rewriters

A rewriter is a script derivation run from the crate directory. It must fail if
the expected source shape is absent. Invoke it from `patchPhase` by
interpolating its store path, for example `${rewriters.wasmerAsNative}`.

Use `helpers.addFile ./payload.rs "src/sys/payload.rs"` for a new source file;
it fails if the destination already exists.
