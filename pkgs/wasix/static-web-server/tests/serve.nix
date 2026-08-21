{
  pkgs,
  harnesses,
  entry,
}: {
  serve = harnesses.hostShell {
    name = "static-web-server-serve";
    hostPackages = [pkgs.curl pkgs.coreutils];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net" "--enable-threads"];
    script = ''
      port=8732
      base="http://127.0.0.1:$port"
      mkdir -p public
      printf '%s\n' 'served by WASIX' > public/index.html

      static-web-server \
        --host 0.0.0.0 \
        --port "$port" \
        --root public \
        --threads-multiplier 1 &
      server_pid=$!
      trap 'kill $server_pid 2>/dev/null || true' EXIT

      for _ in $(seq 1 150); do
        kill -0 $server_pid 2>/dev/null || { echo "static-web-server: server exited early" >&2; exit 1; }
        curl -fsS --max-time 1 "$base/index.html" > response 2>/dev/null && break
        sleep 0.2
      done
      curl -fsS --max-time 5 "$base/index.html" > response \
        || { echo "static-web-server: server never became ready" >&2; exit 1; }
      printf '%s\n' 'served by WASIX' > expected
      cmp expected response
    '';
  };
}
