{
  pkgs,
  testLib,
  wasmerPkgs,
}: {
  serve = testLib.mkWasixRun {
    name = "static-web-server-serve";
    nativePkgs = [pkgs.coreutils pkgs.curl];
    wasixPkgs = [wasmerPkgs.static-web-server];
    wasmerArgs = ["--net" "--enable-threads"];
    script = ''
      port=8732
      base="http://127.0.0.1:$port"
      mkdir -p public
      printf 'hello from WASIX\n' > 'public/hello world.txt'

      # Exercise the legacy command identity used by existing Edge deployments.
      webserver --host 0.0.0.0 --port "$port" --root "$WASIX_TEST_ROOT/public" &
      server_pid=$!
      trap 'kill $server_pid 2>/dev/null || true' EXIT

      for _ in $(seq 1 150); do
        kill -0 $server_pid 2>/dev/null || { echo "webserver: server exited early" >&2; exit 1; }
        curl -fsS "$base/hello%20world.txt" > response.txt 2>/dev/null && break
        sleep 0.2
      done

      cmp response.txt 'public/hello world.txt'
      echo "ok: static-web-server served a percent-encoded path over $base"
    '';
  };
}
