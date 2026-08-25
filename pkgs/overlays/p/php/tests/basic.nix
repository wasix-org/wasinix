{
  entry,
  harnesses,
  packageForEntry,
  packages,
  pkgs,
  ...
}: {
  basic = harnesses.hostShell {
    name = "${entry.name}-basic";
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      cp ${pkgs.dejavu_fonts.minimal}/share/fonts/truetype/DejaVuSans.ttf font.ttf
      cp ${./behavior.php} behavior.php
      php -d phar.readonly=0 behavior.php ${pkgs.lib.escapeShellArg (packageForEntry packages entry).version} "$WASIX_TEST_ROOT/font.ttf"
    '';
  };
}
