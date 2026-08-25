# Reference LAPACK/BLAS/CBLAS for wasix, static archives only. The upstream recipe's
# gfortran is wasixflang in this set (overlay/default.nix), which cmake detects as a
# normal cross Fortran compiler.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  profileOf,
  profileSets,
}:
exposeWasixPackage (
  extendPackage (package.override {shared = false;}) {
    # The archives carry unresolved flang-rt symbols; propagation is what puts its
    # setup hook, and so the runtime, on a consumer's link line.
    propagatedBuildInputs = [packages.native."wasix-sysroot".profiles.${profileOf packages.sameProfile.stdenv.hostPlatform}.flangRt];

    # Appended after nixpkgs' own flags, so BUILD_TESTING=OFF wins over its ON.
    cmakeFlags = [
      "-DBUILD_SHARED_LIBS=OFF"
      "-DBUILD_TESTING=OFF"
    ];

    doInstallCheck = false;

    # flang emits PIC relocations for LAPACK that no relocation-model flag removes, so
    # a non-PIC build fails abiCheck.
    passthru.wasix.supportedProfiles = profileSets.pic;
  }
)
