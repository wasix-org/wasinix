# C and C++

How the C/C++ toolchain becomes the WASIX stdenv used by each profile. Package
authoring is covered by [`packaging.md`](packaging.md).

## Toolchain

The buildable toolchain packages live under `pkgs/overlays/` and are exposed as
ordinary `packages.native` entries. `pkgs/toolchain/` connects them into the
profile interfaces:

- `packages.native.wasix-llvm`: WASIX's LLVM sources through nixpkgs' LLVM
  machinery
- `packages.native.wasix-sysroot`: wasix-libc, compiler-rt, libc++, libc++abi,
  and libunwind, staged into one sysroot per profile
- `packages.native.wasixcc`: the compiler driver around clang, wasm-ld, and
  wasm-opt
- `env.nix`: the canonical `WASIXCC_*` environment

wasixcc selects the profile sysroot at compile time. Its executable dispatches
on `argv[0]`, so the package installs one wrapper per tool name. Package files
must use the environment rendered from `env.nix` instead of exporting
`WASIXCC_*` or `CC=wasixcc` themselves.

## Profiles

A profile combines an exception-handling encoding with PIC or non-PIC output.
For example, `exnrefEh` uses exnref EH, `ehpic` uses legacy Wasm EH with PIC,
and `off` has no Wasm EH. PIC is required for dynamic linking. `fork()` requires
asyncify in every profile; `off` also uses it for `setjmp` and `longjmp`.

`pkgs/project/profiles.nix` is the profile inventory and derives platform
attributes, sysroot flags, directory names, and name lookup from it.

## Cross package sets

The structured project constructor imports nixpkgs once per profile and replaces
its cross stdenv with `pkgs/set/stdenv.nix`. Packages therefore keep ordinary
nixpkgs build conventions while compiling through wasixcc. The public interface
is `packages.native.wasixcc.profiles.<profile>.stdenv`; package units use
`packages.sameProfile` rather than constructing a parallel package graph.

Profile support and selection are described in
[`packaging.md`](packaging.md#a-library). Known libc, runtime, and toolchain
limitations are tracked in [`../WASIX-TODO.md`](../WASIX-TODO.md).
