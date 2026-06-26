# The Rust counterpart to mk-wasix-stdenv: where that wires the wasixcc compiler into a
# profile's cross set as its `stdenv`, this wires the from-source wasix Rust toolchain
# in as its `rustPlatform`. So wasix Rust crates build through the regular machinery
# (vendoring + cargo hooks) with no per-package plumbing — `rustPlatform.buildRustPackage`
# is as transparent as `stdenv.mkDerivation`. Its `buildRustPackage` carries the wasm
# linker fix and the wasixcc C toolchain for build scripts; the overlay injects the
# result as `rustPlatform`.
#
# `pkgsCross` is the repo's plain cross set (nixpkgs' default wasi stdenv, with a real
# libc) — NOT the wasixcc profile stdenv, whose `libc = null` would break nixpkgs' own
# cross rustc/cargo that the cargo hooks build for tooling. The actual compile uses the
# from-source `rustc`, links via the bundled rust-lld, and compiles any C (-sys crates'
# build.rs / cc-rs) with wasixcc. The caller must give pkgsCross
# `rust.rustcTarget = "wasm32-wasmer-wasi"` so the cargo hooks emit the right --target.
{
  lib,
  pkgsCross,
  wasixRustToolchain,
  # The wasixcc C driver for -sys crates' C compilation (its wrapper bakes in the
  # llvm/binaryen/sysroot locations, so nothing else is needed here).
  wasixcc,
  # Host cargo drives the build; the from-source toolchain ships no cargo and cargo
  # is forward-compatible enough to drive the slightly older rustc.
  cargo,
}: let
  hostTriple = "x86_64-unknown-linux-gnu";

  base = pkgsCross.makeRustPlatform {
    rustc = wasixRustToolchain;
    inherit cargo;
  };

  # nixpkgs' rust.envVars forces CARGO_TARGET_<t>_LINKER to the cross clang, which
  # can't parse rustc's raw wasm-lld flags. `cargo --config` outranks that env, so
  # route the link through the toolchain's bundled rust-lld (spec flavor wasm-lld).
  rustLld = "${wasixRustToolchain}/lib/rustlib/${hostTriple}/bin/rust-lld";

  # cc-rs (a -sys crate's build.rs) compiles C for the target with $CC_<target>; point
  # it at the wasixcc wrappers. The wrappers already bake in LLVM/binaryen/sysroot, and
  # wasixcc's defaults (no PIC, legacy EH) match the eh variant the std was built for, so
  # nothing else is needed here. Per-target (not bare CC) so host build scripts /
  # proc-macros keep their normal compiler.
  #
  # NOTE: wasixcc's default is the eh ABI. The ehpic variant (wasm32-wasmer-wasi-dl) would
  # need WASIXCC_PIC=yes added — derive it from the variant when that target is enabled.
  ccEnv = {
    "CC_wasm32-wasmer-wasi" = "${wasixcc}/bin/wasixcc";
    "CXX_wasm32-wasmer-wasi" = "${wasixcc}/bin/wasix++";
    "AR_wasm32-wasmer-wasi" = "${wasixcc}/bin/wasixar";
  };
in
  base
  // {
    buildRustPackage = args:
      base.buildRustPackage (
        {
          # wasm can't run tests on the build host.
          doCheck = false;
          # cargo-auditable would re-link via the cross rustc; unneeded for wasm.
          auditable = false;
        }
        // args
        // {
          cargoBuildFlags =
            ["--config" ''target.wasm32-wasmer-wasi.linker="${rustLld}"'']
            ++ (args.cargoBuildFlags or []);
          env = ccEnv // (args.env or {});
        }
      );
  }
