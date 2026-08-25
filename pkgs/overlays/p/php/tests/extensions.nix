{
  entry,
  harnesses,
  packageForEntry,
  packages,
  pkgs,
  ...
}: let
  inherit (pkgs) lib;
  int64 = lib.hasSuffix "-int64" entry.name;
  baseName = lib.removeSuffix "-int64" entry.name;
  php = packageForEntry packages entry;
  inherit (php) extensions;
  alias = packages.sameProfile.${baseName + "Extensions"};
  extensionVersionsMatch = builtins.all (extension: extension.phpVersion == php.version) (builtins.attrValues extensions);
  extensionSetMatches =
    int64
    || (
      alias.recurseForDerivations
      && toString alias.igbinary == toString extensions.igbinary
      && toString alias.imagick == toString extensions.imagick
    );
  phpWithoutExtensions = php.withExtensions (_: []);
  phpIgbinaryOnly = phpWithoutExtensions.withExtensions ({
    enabled,
    all,
    ...
  }:
    enabled ++ [all.igbinary]);
  igbinaryCommand = harnesses.packageCommand {
    package = phpIgbinaryOnly;
    name = "php";
  };
in
  assert extensionVersionsMatch;
  assert extensionSetMatches; {
    package-sets = pkgs.runCommand "${entry.name}-extension-package-sets" {} ''
      echo "php extension package sets match" >"$out"
    '';

    extensions-default = harnesses.hostShell {
      name = "${entry.name}-extensions-default";
      wasixCommands = builtins.attrValues entry.commands;
      script = ''
        php -r 'exit(extension_loaded("igbinary") && extension_loaded("imagick") ? 0 : 1);'
      '';
    };

    igbinary-only = harnesses.hostShell {
      name = "${entry.name}-igbinary-only";
      wasixCommands = [igbinaryCommand];
      script = ''
        php -r 'exit(extension_loaded("igbinary") && !extension_loaded("imagick") ? 0 : 1);'
      '';
    };
  }
