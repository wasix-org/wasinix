{
  exposePackageVariants,
  extendPackage,
  packageSet,
}: let
  native = packageSet.callPackage ./build.nix {};
  wasix = extendPackage native {
    passthru.wasinix = {
      shipped = true;
      retention = "none";
    };
  };
in
  exposePackageVariants {inherit native wasix;}
