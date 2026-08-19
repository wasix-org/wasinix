{
  crossPkgs,
  makeWasmerPackage,
  testLib,
  ...
}: let
  phpIgbinaryOnly = crossPkgs.php85.withExtensions ({all, ...}: [all.igbinary]);
  phpInt64IgbinaryOnly = crossPkgs.php85-int64.withExtensions ({all, ...}: [all.igbinary]);
in {
  extensions-default = testLib.mkWasixRun {
    name = "php85-extensions-default";
    wasixPkgs = [(makeWasmerPackage {package = crossPkgs.php85;}).shim];
    script = ''
      php -r 'exit(extension_loaded("igbinary") && extension_loaded("imagick") ? 0 : 1);'
    '';
  };

  igbinary-only = testLib.mkWasixRun {
    name = "php85-igbinary-only";
    wasixPkgs = [(makeWasmerPackage {package = phpIgbinaryOnly;}).shim];
    script = ''
      php -r 'exit(extension_loaded("igbinary") && !extension_loaded("imagick") ? 0 : 1);'
    '';
  };

  int64-igbinary-only = testLib.mkWasixRun {
    name = "php85-int64-igbinary-only";
    wasixPkgs = [(makeWasmerPackage {package = phpInt64IgbinaryOnly;}).shim];
    script = ''
      php -r 'exit(PHP_INT_SIZE === 8 && extension_loaded("igbinary") && !extension_loaded("imagick") ? 0 : 1);'
    '';
  };
}
