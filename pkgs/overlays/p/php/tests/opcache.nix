{
  entry,
  harnesses,
  ...
}: {
  opcache = harnesses.hostShell {
    name = "${entry.name}-opcache";
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      printf '%s\n' '<?php return 42;' > opcache-target.php
      php -d opcache.error_log=/dev/stderr -d display_startup_errors=1 -r '
        $path = getcwd() . "/opcache-target.php";
        if (!function_exists("opcache_get_status")) {
          throw new RuntimeException("opcache API missing");
        }
        if (opcache_get_status(false) === false) {
          throw new RuntimeException(json_encode([
            "opcache.enable" => ini_get("opcache.enable"),
            "opcache.enable_cli" => ini_get("opcache.enable_cli")
          ]));
        }
        if (!opcache_compile_file($path) || !opcache_is_script_cached($path)) {
          throw new RuntimeException("opcache did not cache script");
        }
        echo "php opcache ok\n";
      '
    '';
  };
}
