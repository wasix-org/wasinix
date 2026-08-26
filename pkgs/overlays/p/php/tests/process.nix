{
  entry,
  harnesses,
  ...
}: {
  process = harnesses.hostShell {
    name = "${entry.name}-process";
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      php -r '
        $descriptors = [
          ["pipe", "r"],
          ["pipe", "w"],
          ["pipe", "w"]
        ];
        $process = proc_open(
          ["php", "-r", "fwrite(STDOUT, strtoupper(stream_get_contents(STDIN))); fwrite(STDERR, getenv(\"PHP_CHILD\")); exit(7);"],
          $descriptors,
          $pipes,
          null,
          ["PHP_CHILD" => "child-stderr"]
        );
        if (!is_resource($process)) {
          throw new RuntimeException("proc_open failed");
        }
        fwrite($pipes[0], "child-stdin");
        fclose($pipes[0]);
        $stdout = stream_get_contents($pipes[1]);
        $stderr = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $status = proc_close($process);
        if ($stdout !== "CHILD-STDIN" || $stderr !== "child-stderr" || $status !== 7) {
          throw new RuntimeException(json_encode([$stdout, $stderr, $status]));
        }
        echo "php process ok\n";
      '
    '';
  };
}
