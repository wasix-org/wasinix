{
  crossPkgs,
  helpers,
  makeWasmerPackage,
  pkgs,
  testLib,
  ...
}: let
  attrs = builtins.attrNames (import ../versions.nix);
  wasmerPkgs = helpers.mkPhpShims "" {inherit crossPkgs makeWasmerPackage;};
in
  builtins.listToAttrs (pkgs.lib.imap0 (index: attr: let
      httpPort = 8800 + index * 3;
      httpsPort = httpPort + 1;
      phpPort = httpPort + 2;
    in {
      name = "${attr}-network";
      value = testLib.mkWasixRun {
        name = "${attr}-network";
        nativePkgs = [pkgs.coreutils pkgs.curl pkgs.lighttpd pkgs.openssl];
        wasixPkgs = [wasmerPkgs.${attr}];
        wasmerArgs = ["--net"];
        script = ''
          mkdir -p docroot
          printf 'hello from php network\n' > docroot/hello.txt
          openssl req -x509 -newkey rsa:2048 \
            -keyout server.key -out server.crt -days 1 -nodes \
            -subj '/CN=127.0.0.1' -addext 'subjectAltName=IP:127.0.0.1' \
            >/dev/null 2>&1

          cat > lighttpd-http.conf <<EOF
          server.document-root = "$(pwd)/docroot"
          server.port = ${toString httpPort}
          server.bind = "127.0.0.1"
          server.errorlog = "$(pwd)/lighttpd-http.log"
          EOF
          lighttpd -D -f lighttpd-http.conf &
          http_pid=$!

          cat > lighttpd-https.conf <<EOF
          server.document-root = "$(pwd)/docroot"
          server.port = ${toString httpsPort}
          server.bind = "127.0.0.1"
          server.modules = ("mod_openssl")
          server.errorlog = "$(pwd)/lighttpd-https.log"
          ssl.engine = "enable"
          ssl.pemfile = "$(pwd)/server.crt"
          ssl.privkey = "$(pwd)/server.key"
          EOF
          lighttpd -D -f lighttpd-https.conf &
          https_pid=$!
          trap 'kill $http_pid $https_pid ''${php_pid:-} 2>/dev/null || true' EXIT

          for url in \
            http://127.0.0.1:${toString httpPort}/hello.txt \
            https://127.0.0.1:${toString httpsPort}/hello.txt; do
            for _ in $(seq 1 50); do
              curl -kfsS "$url" >/dev/null 2>&1 && break
              sleep 0.1
            done
            curl -kfsS "$url" >/dev/null
          done

          mkdir php-docroot
          cat > php-docroot/index.php <<'PHP'
          <?php
          $route = $_GET["route"] ?? "";
          if ($route === "json") {
              if ($_SERVER["REQUEST_METHOD"] !== "POST" || ($_SERVER["CONTENT_TYPE"] ?? "") !== "application/json") {
                  http_response_code(400);
                  exit;
              }
              header("Content-Type: application/json");
              echo file_get_contents("php://input");
          } elseif ($route === "extensions") {
              $database = new PDO("sqlite::memory:");
              $image = imagecreatetruecolor(2, 3);
              header("Content-Type: text/plain");
              echo $database->query("select 40 + 2")->fetchColumn(), " ", imagesx($image), "x", imagesy($image), "\n";
          } else {
              header("Content-Type: text/plain");
              echo $_SERVER["REQUEST_METHOD"], " ", $_SERVER["REQUEST_URI"], " ", file_get_contents("php://input"), "\n";
          }
          PHP
          php -S localhost:${toString phpPort} -t "$WASIX_TEST_ROOT/php-docroot" >php-server.log 2>&1 &
          php_pid=$!
          for _ in $(seq 1 300); do
            kill -0 "$php_pid" 2>/dev/null || { cat php-server.log >&2; exit 1; }
            response=$(curl -fsS -X POST --data 'request body' 'http://127.0.0.1:${toString phpPort}/index.php?route=echo' 2>/dev/null) || true
            [ "$response" = 'POST /index.php?route=echo request body' ] && break
            sleep 0.1
          done
          if [ "$response" != 'POST /index.php?route=echo request body' ]; then
            echo "unexpected PHP server response: $response" >&2
            cat php-server.log >&2
            exit 1
          fi
          extension_response=$(curl -fsS 'http://127.0.0.1:${toString phpPort}/index.php?route=extensions')
          if [ "$extension_response" != '42 2x3' ]; then
            echo "unexpected PHP extension response: $extension_response" >&2
            cat php-server.log >&2
            exit 1
          fi

          cp ${./network.php} network.php
          php network.php \
            http://127.0.0.1:${toString httpPort}/hello.txt \
            https://127.0.0.1:${toString httpsPort}/hello.txt \
            "$WASIX_TEST_ROOT/server.crt" \
            'http://127.0.0.1:${toString phpPort}/index.php?route=json'
          echo 'php cli server ok'
        '';
      };
    })
    attrs)
