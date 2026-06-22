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
  package.overrideAttrs (
    old:
      {
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [toolchain.wasixcc] ++ extraNativeBuildInputs;
        buildInputs = (old.buildInputs or []) ++ extraBuildInputs;
        propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ extraPropagatedBuildInputs;

        postPatch = mergeScript [
          (old.postPatch or "")
          postPatch
        ];

        preConfigure = mergeScript [
          toolchain.toolchainEnv
          toolchain.ccEnv
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
