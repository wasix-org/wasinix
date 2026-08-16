# Rust

How Rust builds reach WASIX and how patched crates are shared with plain cargo.
Adding a package is covered by [`packaging.md`](packaging.md#a-rust-cli).

## Building for WASIX

`pkgs/toolchain/rust/` builds the WASIX Rust sources and cargo-wasix.
`pkgs/set/rust-platform.nix` routes `buildRustPackage` through cargo-wasix and
provides the WASIX defaults. Rust has a standard library for `eh` and `ehpic`,
so Rust packages are limited to those profiles.

A nixpkgs CLI usually needs only `{ prev, ... }: prev.foo`. For a crate nixpkgs
does not carry, use `final.rustPlatform.buildRustPackage`; see
`pkgs/overlay/packages/crabsay.nix`. Python wheels use the shared maturin and
setuptools-rust hooks.

## Crate edits

Every WASIX Rust builder applies matching edits from
`pkgs/lib/wasix-crate-patches/` to its vendored crates. The same edit
definitions feed the overlay registry, so package builds and published crates
cannot drift.

The edit format, version coverage, dependency additions, and source rewriters
are documented in
[`pkgs/lib/wasix-crate-patches/README.md`](../pkgs/lib/wasix-crate-patches/README.md).

## Cargo registry

`cargo-registry.wasix.org` publishes edited crates as `<upstream>+wasix.N`,
allowing plain cargo projects to select them by version.

- `wasinix update cargo-registry` re-resolves the crate versions and hashes.
- `.#cargoRegistry` builds the registry contents.
- `.#checks.x86_64-linux.cargo-registry` checks the mint and resolution.
- `wasinix cargo serve` serves a fresh local registry under Wasmer.

The server package is `wasmerPackages.wasix-cargo-registry`.
