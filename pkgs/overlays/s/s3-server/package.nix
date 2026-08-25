{
  exposePackageVariants,
  extendPackage,
  packageSet,
}: let
  native = packageSet.callPackage ./build.nix {};
  wasix = extendPackage native {passthru.wasinix.shipped = true;};
in
  exposePackageVariants {inherit native wasix;}
