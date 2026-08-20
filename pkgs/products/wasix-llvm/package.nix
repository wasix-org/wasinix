# The wasix-org LLVM fork (clang/lld/llvm), built via nixpkgs' llvmPackages with
# the fork source swapped in. Built once on the host x86_64; it is both the
# shipped toolchain and the compiler that builds the sysroot runtimes.
{
  pkgs,
  nix-update-script,
}: let
  version = "21.1.206"; # fork release: base 21.1.2 plus a 2-digit counter
  # The base is the release minus the counter. Lenient (echoes strings it
  # cannot parse) so the update-note predicate below never throws on old
  # recorded versions; llvmVersion asserts the scheme instead.
  baseOf = tag: let
    parts = pkgs.lib.splitVersion tag;
    patch = builtins.elemAt parts 2;
  in
    if builtins.length parts != 3 || builtins.stringLength patch < 3
    then tag
    else
      "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}."
      + builtins.substring 0 (builtins.stringLength patch - 2) patch;
  llvmVersion =
    if baseOf version == version
    then throw "llvm fork release '${version}' does not look like <major>.<minor>.<base-patch>NN; derive the base by hand"
    else baseOf version;
  # nixpkgs ships one llvmPackages (and patch set) per major, so the scope
  # follows the fork's major; a bump nixpkgs has no scope for fails eval.
  llvmPackages = pkgs."llvmPackages_${pkgs.lib.versions.major version}";
  monorepoSrc = pkgs.fetchFromGitHub {
    owner = "wasix-org";
    repo = "llvm-project";
    tag = version;
    hash = "sha256-TKvDtvvCi1mOhYvbb7kHK7cWezZp/XyaydZY1ZJQR4g=";
  };

  # The stock compiler-rt/libcxx are invalid for wasix and the replacements are
  # per-ABI-variant, so override them with a throw pointing at variants.<v>. Safe:
  # the pieces we use (clang-unwrapped/lld/llvm/monorepoSrc) don't depend on them.
  perVariant = comp:
    throw "toolchain.llvm.${comp}: wasix ${comp} is per-ABI-variant; there is no single one. Use toolchain.variants.<variant>.${comp} (e.g. variants.exnrefEh.${comp}).";
  llvm =
    (llvmPackages.override (_old: {
      officialRelease = {};
      # the base: release_version drives nixpkgs' version gates and the
      # build-time source check, both baked in at scope construction
      version = llvmVersion;
      src = monorepoSrc;
      inherit monorepoSrc;
      doCheck = false;
    })).overrideScope
    (
      final: prev: {
        compiler-rt = perVariant "compiler-rt";
        libcxx = perVariant "libcxx";
        # The drvs are the fork, so version them by its release (the baked-in
        # release_version above is untouched by this). `pos` restamps
        # meta.position to this file, where the pin lives (mkDerivation derives
        # meta.position from pos, clobbering a meta.position attr).
        libllvm = prev.libllvm.overrideAttrs (_old: {
          inherit version;
          __intentionallyOverridingVersion = true;
        });
        lld = prev.lld.overrideAttrs (_old: {
          inherit version;
          __intentionallyOverridingVersion = true;
        });
        clang-unwrapped = prev.clang-unwrapped.overrideAttrs (_old: {
          inherit version;
          __intentionallyOverridingVersion = true;
          pos = __curPos;
        });
        # Update metadata rides on clang because that is the fork drv in the ci
        # job set (toolchain.llvm.clang). nix-update finds the file to edit at
        # the version attr's definition site, which through overrideAttrs still
        # points into nixpkgs; `pin` is the pin as a record of its own, with
        # version and src defined here.
        clang = prev.clang.overrideAttrs (old: {
          pos = __curPos;
          passthru =
            (old.passthru or {})
            // {
              unwrapped = final.clang-unwrapped;
              pin = pkgs.runCommand "wasix-llvm-pin" {
                inherit version;
                src = monorepoSrc;
                pos = __curPos;
              } "touch $out";
              updateScript = {
                name = "llvm"; # attr tail is `clang`
                # the fork also carries non-release tags (wasixrel-*, llvmorg-*)
                command = nix-update-script {
                  extraArgs = [
                    "--flake"
                    "--version-regex"
                    "^([0-9.]+)$"
                  ];
                };
                attrPath = "toolchain.llvm.clang.pin";
                accepts = ["release" "revision"];
                source = {
                  kind = "github";
                  owner = "wasix-org";
                  repo = "llvm-project";
                };
              };
              wasix.updateNotes = [
                {
                  name = "llvm";
                  message = "the base LLVM version moved with this bump and nixpkgs' patch selection switched with it; check the toolchain build and the applied patches";
                  when = prior: current: prior != null && current != null && baseOf prior != baseOf current;
                }
              ];
            };
        });
      }
    );

  # Single LLVM install tree (clang, wasm-ld, llvm-*, clang's resource dir) for
  # consumers that need one location, notably wasixcc's WASIXCC_LLVM_LOCATION.
  llvmTree = pkgs.symlinkJoin {
    name = "wasix-llvm-${version}";
    paths = [
      llvm.clang-unwrapped
      llvm.lld
      llvm.llvm
    ];
  };
in
  # One derivation so the products loader can carry it; the pieces the toolchain
  # and the overlay need ride along as passthru.
  llvmTree.overrideAttrs (old: {
    meta =
      (old.meta or {})
      // {
        description = "WASIX LLVM toolchain";
        longDescription = "The WASIX LLVM, Clang, LLD, and LLVM utility toolchain built from the wasix-org LLVM fork.";
        homepage = "https://github.com/wasix-org/llvm-project";
        changelog = "https://github.com/wasix-org/llvm-project/releases/tag/${version}";
        license = llvm.clang-unwrapped.meta.license;
        platforms = ["x86_64-linux"];
      };
    passthru =
      (old.passthru or {})
      // {
        inherit version llvmVersion monorepoSrc llvm;
      };
  })
