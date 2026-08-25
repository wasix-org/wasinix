{
  entry,
  harnesses,
  packageForEntry,
  packages,
  pkgs,
  ...
}:
pkgs.lib.optionalAttrs (pkgs.lib.versionAtLeast (packageForEntry packages entry).version "8.1") {
  fibers = harnesses.hostShell {
    name = "${entry.name}-fibers";
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      php -r '
        $fiber = new Fiber(function () {
          $value = Fiber::suspend("suspended");
          return "returned:" . $value;
        });
        if ($fiber->start() !== "suspended" || !$fiber->isSuspended()) {
          throw new RuntimeException("fiber did not suspend");
        }
        $fiber->resume("resumed");
        if (!$fiber->isTerminated() || $fiber->getReturn() !== "returned:resumed") {
          throw new RuntimeException("fiber did not resume");
        }
        echo "php fibers ok\n";
      '
    '';
  };
}
