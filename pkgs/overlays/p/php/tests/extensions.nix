{
  crossPkgs,
  makeWasmerPackage,
  testLib,
  ...
}: let
  versionNames = builtins.attrNames (import ../versions.nix);
  extensionSetNames = ["php"] ++ versionNames;
  extensionVersionsMatch = php:
    builtins.all (extension: extension.phpVersion == php.version) (builtins.attrValues php.extensions);
  extensionSetsMatch = builtins.all (name: let
    alias = crossPkgs.${"${name}Extensions"};
    php = crossPkgs.${name};
    extensions = php.extensions;
  in
    alias.recurseForDerivations
    && extensionVersionsMatch php
    && toString alias.igbinary == toString extensions.igbinary
    && toString alias.imagick == toString extensions.imagick)
  extensionSetNames;
  int64ExtensionVersionsMatch = builtins.all (name: extensionVersionsMatch crossPkgs.${"${name}-int64"}) versionNames;
  phpWithoutExtensions = crossPkgs.php85.withExtensions (_: []);
  phpInt64WithoutExtensions = crossPkgs.php85-int64.withExtensions (_: []);
  phpIgbinaryOnly = phpWithoutExtensions.withExtensions ({
    enabled,
    all,
  }:
    enabled ++ [all.igbinary]);
  phpInt64IgbinaryOnly = phpInt64WithoutExtensions.withExtensions ({
    enabled,
    all,
  }:
    enabled ++ [all.igbinary]);
in
  assert extensionSetsMatch;
  assert int64ExtensionVersionsMatch; {
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
