{
  crossPkgs,
  makeWasmerPackage,
  testLib,
  ...
}: let
  extensionSetNames = ["php"] ++ builtins.attrNames (import ../versions.nix);
  extensionSetsMatch = builtins.all (name: let
    alias = crossPkgs.${"${name}Extensions"};
    extensions = crossPkgs.${name}.extensions;
  in
    alias.recurseForDerivations
    && toString alias.igbinary == toString extensions.igbinary
    && toString alias.imagick == toString extensions.imagick)
  extensionSetNames;
  phpIgbinaryOnly = crossPkgs.php85.withExtensions ({all, ...}: [all.igbinary]);
  phpInt64IgbinaryOnly = crossPkgs.php85-int64.withExtensions ({all, ...}: [all.igbinary]);
in
  assert extensionSetsMatch; {
    package-sets = testLib.mkScriptRun {
      name = "php-extension-package-sets";
      packages = [];
      script = ''
        echo "php extension package sets match"
      '';
    };

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
