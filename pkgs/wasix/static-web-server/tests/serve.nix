{
  pkgs,
  testLib,
  wasmerPkgs,
}: let
  taskset = pkgs.lib.getExe' pkgs.util-linux "taskset";
in {
  serve = testLib.mkWasixRun {
    name = "static-web-server-serve";
    nativePkgs = [pkgs.curl pkgs.coreutils];
    wasixPkgs = [wasmerPkgs.static-web-server];
    wasmerArgs = ["--net" "--enable-threads"];
    script = ''
      port=$((20000 + $$ % 20000))
      base="http://127.0.0.1:$port"
      mkdir -p public
      printf '%s\n' 'served by WASIX' > public/index.html

      affinity="$(${taskset} --pid --cpu-list $$)"
      affinity="''${affinity##*: }"
      cpu="''${affinity%%,*}"
      cpu="''${cpu%%-*}"
      case "$cpu" in
        "" | *[!0-9]*) echo "taskset: could not parse CPU list: $affinity" >&2; exit 1 ;;
      esac

      ${taskset} --cpu-list "$cpu" static-web-server \
        --host 0.0.0.0 \
        --port "$port" \
        --root public \
        --threads-multiplier 1 \
        --log-level debug > server.log 2>&1 &
      server_pid=$!
      trap 'kill $server_pid 2>/dev/null || true' EXIT

      for _ in $(seq 1 150); do
        kill -0 $server_pid 2>/dev/null \
          || { echo "static-web-server: server exited early" >&2; cat server.log >&2; exit 1; }
        curl -fsS --max-time 1 "$base/index.html" > response 2>/dev/null && break
        sleep 0.2
      done
      curl -fsS --max-time 5 "$base/index.html" > response \
        || { echo "static-web-server: server never became ready" >&2; cat server.log >&2; exit 1; }
      printf '%s\n' 'served by WASIX' > expected
      cmp expected response
    '';
  };
}
