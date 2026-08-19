{
  crossPkgs,
  helpers,
  makeWasmerPackage,
  pkgs,
  testLib,
  ...
}: let
  versions = pkgs.lib.filterAttrs (_: spec: pkgs.lib.versionAtLeast spec.version "8.1") (import ../versions.nix);
  wasmerPkgs = helpers.mkPhpShims "" {inherit crossPkgs makeWasmerPackage;};
in
  pkgs.lib.mapAttrs' (attr: _:
    pkgs.lib.nameValuePair "${attr}-fibers" (testLib.mkWasixRun {
      name = "${attr}-fibers";
      wasixPkgs = [wasmerPkgs.${attr}];
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
    }))
  versions
