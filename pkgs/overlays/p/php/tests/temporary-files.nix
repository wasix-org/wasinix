{
  entry,
  harnesses,
  ...
}: {
  temporary-files = harnesses.hostShell {
    name = "${entry.name}-temporary-files";
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      php -r '
        $path = tempnam(sys_get_temp_dir(), "php-");
        if ($path === false || file_put_contents($path, "temporary") !== 9) {
          $errno = posix_get_last_error();
          throw new RuntimeException("tempnam failed: " . $errno . " " . posix_strerror($errno));
        }
        unlink($path);
        $stream = tmpfile();
        if ($stream === false || fwrite($stream, "temporary") !== 9) {
          throw new RuntimeException("tmpfile failed: " . json_encode(error_get_last()));
        }
        fclose($stream);
        echo "php temporary files ok\n";
      '
    '';
  };
}
