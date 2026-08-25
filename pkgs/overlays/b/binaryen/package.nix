{
  exposeExtendedPackage,
  lib,
  packageSet,
  scope,
}:
exposeExtendedPackage (
  {
    patches = [
      (packageSet.fetchpatch {
        name = "binaryen-fix-wrapper-block-binary-spans.patch";
        url = "https://github.com/WebAssembly/binaryen/commit/eac45bc00e7ae871263c3f431389aa916f146f1e.patch";
        hash = "sha256-4gEw4l895QPlhMk3n9fgSIxNY3d9Fz5lG2JpMV/Dt8g=";
      })
    ];
  }
  // lib.optionalAttrs (scope == "wasix") {
    passthru.wasinix.ci.profiles = ["exnrefEhpic"];
  }
)
