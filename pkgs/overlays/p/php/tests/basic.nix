{
  entry,
  harnesses,
  packageForEntry,
  packages,
  pkgs,
  ...
}: let
  expectedIntSize =
    if pkgs.lib.hasSuffix "-int64" entry.name
    then "8"
    else "4";
in {
  basic = harnesses.hostShell {
    name = "${entry.name}-basic";
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      cp ${pkgs.dejavu_fonts.minimal}/share/fonts/truetype/DejaVuSans.ttf font.ttf
      cp ${./behavior.php} behavior.php
      php -d phar.readonly=0 behavior.php \
        ${pkgs.lib.escapeShellArg (packageForEntry packages entry).version} \
        ${expectedIntSize} \
        "$WASIX_TEST_ROOT/font.ttf"
    '';
  };
}
