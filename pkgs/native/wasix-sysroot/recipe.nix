# The from-source wasix sysroot, mirroring wasix-libc's build32-general.sh: per ABI
# variant, libc then compiler-rt then libc++, each staged against the previous. The
# combined `sysroot` holds one subdir per variant, as WASIXCC_SYSROOT_PREFIX expects.
{
  pkgs,
  wasix-llvm,
  wasix-flang,
  ...
}: let
  inherit (wasix-llvm.passthru) llvm llvmVersion;
  flang = wasix-flang;
  inherit (pkgs) lib;
  # One sysroot variant per profile, encoded {eh, pic, exnref}; PIC needs EH.
  profilesCfg = import ../../project/profiles.nix;

  # The pin lives in libc.nix next to the witx pins; the per-variant libc drvs
  # share it as their src.
  wasixLibcSrc = (pkgs.callPackage ./libc.nix {}).src;

  # wasix-libc's committed toolchain files are the single source of the ABI flags.
  # PIC is a cmake arg, not a separate file.
  toolchainFileFor = {
    eh,
    exnref,
  }:
    if !eh
    then "${wasixLibcSrc}/tools/clang-wasix.cmake_toolchain"
    else if exnref
    then "${wasixLibcSrc}/tools/clang-wasix-exnref-eh.cmake_toolchain"
    else "${wasixLibcSrc}/tools/clang-wasix-eh.cmake_toolchain";

  # A real copy, not symlinkJoin: components install into the SAME dirs and
  # cmake/clang resolve --sysroot paths through the tree. --no-preserve=mode lets
  # later components merge into the read-only store copies.
  mkSysroot = sname: comps:
    pkgs.runCommand "wasix-sysroot-${sname}" {} (
      ''
        mkdir -p "$out"
      ''
      + lib.concatMapStrings (c: ''
        cp -r --no-preserve=mode,ownership ${c}/. "$out/"
      '')
      comps
    );

  # stdenvNoCC has no compiler env, so export the tools the cmake hook and toolchain
  # file read. The prefix-map is computed here because it needs the source path
  # ($PWD before the hook cd's into ./build) and clang's resource dir.
  runtimesPreConfigure = ''
    export CC=clang CXX=clang++ NM=llvm-nm AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
    resource_dir="$(clang -print-resource-dir)"
    prefix_map="-ffile-prefix-map=$PWD=. -ffile-prefix-map=$resource_dir=/clang"
    cmakeFlagsArray+=(
      "-DCMAKE_C_FLAGS=$prefix_map"
      "-DCMAKE_CXX_FLAGS=$prefix_map"
      "-DCMAKE_ASM_FLAGS=$prefix_map"
    )
  '';

  mkVariant = {
    name,
    eh,
    pic,
    exnref,
  }: let
    toolchainFile = toolchainFileFor {inherit eh exnref;};

    libc = pkgs.callPackage ./libc.nix {inherit eh pic exnref;};

    compiler-rt = pkgs.callPackage ./compiler-rt.nix {
      inherit name pic llvm toolchainFile runtimesPreConfigure;
      version = llvmVersion;
      sysroot = mkSysroot "${name}-rtdeps" [libc];
    };

    libcxx = pkgs.callPackage ./libcxx.nix {
      inherit name eh pic llvm toolchainFile runtimesPreConfigure;
      version = llvmVersion;
      sysroot = mkSysroot "${name}-cxxdeps" [libc compiler-rt];
    };

    # Matches the release tarballs: off -> sysroot, eh -> sysroot-eh, and so on.
    sysrootSubdir = profilesCfg.sysrootSubdirs.${name};

    sysroot = mkSysroot name [libc compiler-rt libcxx];

    # The Fortran and OpenMP runtimes stage against the full sysroot, unlike
    # compiler-rt and libcxx, which build the stages it is made of.
    flangRt = pkgs.callPackage ./flang-rt.nix {
      inherit name pic flang llvm toolchainFile sysroot runtimesPreConfigure;
      version = llvmVersion;
    };

    openmp = pkgs.callPackage ./openmp.nix {
      inherit name pic llvm toolchainFile sysroot runtimesPreConfigure;
      version = llvmVersion;
    };

    test = pkgs.callPackage ./tests/sysroot-test.nix {
      inherit name eh pic toolchainFile sysroot llvm;
    };
  in {
    inherit name eh pic exnref libc compiler-rt libcxx sysrootSubdir sysroot flangRt openmp test;
  };

  variants =
    lib.mapAttrs (name: enc: mkVariant (enc // {inherit name;}))
    profilesCfg.sysrootEncodings;

  sysroot = pkgs.runCommand "wasix-sysroot" {} (
    ''
      mkdir -p "$out"
    ''
    + lib.concatMapStrings (v: ''
      ln -s ${v.sysroot} "$out/${v.sysrootSubdir}"
    '') (lib.attrValues variants)
  );

  tests = lib.mapAttrs (_: v: v.test) variants;
in
  # One derivation for the products loader; the per-variant pieces ride along as
  # passthru. The undecorated component attrs are the `off` variant.
  sysroot.overrideAttrs (old: {
    meta =
      (old.meta or {})
      // {
        description = "WASIX C/C++ sysroot";
        longDescription = "The combined WASIX libc, compiler-rt, libc++, and libc++abi sysroot for the repository's toolchain profiles.";
        homepage = "https://github.com/wasix-org/wasix-libc";
        license = pkgs.lib.unique (pkgs.lib.flatten [variants.off.libc.meta.license variants.off.compiler-rt.meta.license variants.off.libcxx.meta.license]);
        platforms = ["x86_64-linux"];
      };
    passthru =
      (old.passthru or {})
      // {inherit variants tests;}
      // {inherit (variants.off) libc compiler-rt libcxx;};
  })
