# wasix-crate-patches

Versioned wasix patches for vendored Rust crates, applied automatically by
`../wasix-vendor-patch-hook.sh` (a preBuild hook in the rust build platform).
Packages stay plain `buildRustPackage { cargoHash = ...; }`; the hook patches the
vendored sources in the sandbox before `cargo build`.

Interim rust-app path: patch the real-code leaf crates and let cargo's
one-copy-per-version vendoring propagate the fix, so stock upstream builds
unchanged. Cheap to delete once the WASIX v2 toolchain (`cfg(unix)`) lands.

## Layout

    <crate>/<version>.patch     e.g. tokio/1.47.0.patch

`<crate>` is the exact crate name; `<version>` a bare semver.

## Version selection (semver floor)

For a vendored `<crate>-<V>`, the highest patch version `<= V` is applied; a patch
at `X` covers `[X, next-patch)`. When upstream moves out from under it the build
fails loud -- add a new `<V>.patch`. Versions below the lowest patch are stock.

## Authoring

Export the delta from the crate's `wasix-*` fork branch, relative to the crate
root so it applies with `patch -p1`:

    git -C <fork> diff [--relative=<member>] <upstream-tag> <wasix-branch> \
      > <crate>/<version>.patch

## Scope

Any vendored crate needing a real wasix source change: `getrandom`,
`target-lexicon`, `esaxx-rs`, `pyo3-async-runtimes`, and the leaves apps hit
transitively (`tokio`, `mio`, `socket2`, TLS). Not `hyper`/`tower`/`reqwest`/etc.
-- those build stock once the leaves are patched.
