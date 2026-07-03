# e2e tests for phpix: run mode (script execution) and serve mode (a real
# HTTP round trip — phpix.wasm listening under wasmer --net, curl from host).
{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: {
  version = testLib.mkWasixRun {
    name = "phpix-version";
    wasixPkgs = [wasmerPkgs.phpix];
    script = "phpix --version";
  };

  # `phpix run`: execute a script, exercising the embedded libphp (core, json,
  # pcre) without networking.
  run-script = testLib.mkWasixRun {
    name = "phpix-run-script";
    wasixPkgs = [wasmerPkgs.phpix];
    script = ''
      cat > hello.php <<'PHP'
      <?php
      echo "hello from " . PHP_VERSION . "\n";
      echo json_encode(["sum" => array_sum([1, 2, 3])]) . "\n";
      preg_match('/w(as)ix/', 'wasix', $m);
      echo $m[1] . "\n";
      PHP
      out=$(phpix run hello.php)
      echo "$out"
      echo "$out" | grep -q '^hello from 8\.5'
      echo "$out" | grep -q '^{"sum":6}$'
      echo "$out" | grep -q '^as$'
    '';
  };

  # `phpix serve`: start the server in the guest, then drive it from the host
  # with curl — GET with query-string dispatch and a POST body round trip.
  serve-http = testLib.mkWasixRun {
    name = "phpix-serve-http";
    nativePkgs = [pkgs.curl];
    wasixPkgs = [wasmerPkgs.phpix];
    wasmerArgs = ["--net"];
    script = ''
      mkdir docroot
      cat > docroot/index.php <<'PHP'
      <?php
      header('Content-Type: text/plain');
      echo "echo:" . ($_GET['msg'] ?? 'none') . ";post:" . file_get_contents('php://input');
      PHP

      phpix -S 127.0.0.1:8123 -t docroot --php-threads 2 &
      server_pid=$!

      # First request also JIT-compiles the module; give it a generous window.
      for _ in $(seq 1 120); do
        curl -fsS -o /dev/null 'http://127.0.0.1:8123/index.php?msg=up' 2>/dev/null && break
        sleep 1
      done

      body=$(curl -fsS 'http://127.0.0.1:8123/index.php?msg=hello')
      echo "$body"
      [ "$body" = "echo:hello;post:" ]

      post=$(curl -fsS -d 'ping' 'http://127.0.0.1:8123/index.php')
      echo "$post"
      [ "$post" = "echo:none;post:ping" ]

      kill "$server_pid" 2>/dev/null || true
    '';
  };
}
