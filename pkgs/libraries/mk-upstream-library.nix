{
  lib,
  toolchain,
}: {
  package,
  extraNativeBuildInputs ? [],
  extraBuildInputs ? [],
  extraPropagatedBuildInputs ? [],
  preConfigure ? "",
  postPatch ? "",
  preBuild ? "",
  postInstall ? "",
  configureFlags ? [],
  makeFlags ? [],
  env ? {},
  doCheck ? null,
  overrideAttrs ? (_old: {}),
}: let
  mergeScript = fragments:
    lib.concatStringsSep "\n" (lib.filter (fragment: fragment != "" && fragment != null) fragments);
in
  # Build the upstream package through the first-class wasix cross stdenv
  # (cc-wrapper around wasixcc) rather than re-using nixpkgs' cross stdenv and
  # env-injecting CC=wasixcc. The stdenv already supplies $CC/$CXX (= wasixcc),
  # the WASIXCC_* knobs (baked into its shim), and buildInputs → -I/-L
  # propagation, so we no longer thread toolchain.{toolchainEnv,ccEnv} or add
  # toolchain.wasixcc to nativeBuildInputs.
  (package.override {stdenv = toolchain.stdenv;}).overrideAttrs (
    old:
      {
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ extraNativeBuildInputs;
        buildInputs = (old.buildInputs or []) ++ extraBuildInputs;
        propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ extraPropagatedBuildInputs;

        postPatch = mergeScript [
          (old.postPatch or "")
          postPatch
        ];

        preConfigure = mergeScript [
          (old.preConfigure or "")
          preConfigure
        ];

        preBuild = mergeScript [
          (old.preBuild or "")
          preBuild
        ];

        postInstall = mergeScript [
          (old.postInstall or "")
          postInstall
        ];

        configureFlags = (old.configureFlags or []) ++ configureFlags;
        makeFlags = (old.makeFlags or []) ++ makeFlags;
        env = (old.env or {}) // env;
      }
      // lib.optionalAttrs (doCheck != null) {
        inherit doCheck;
      }
      // overrideAttrs old
  )
