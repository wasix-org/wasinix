{
  commands,
  harnesses,
  pkgs,
  ...
}: let
  fixture = pkgs.runCommand "wasix-shell-fixture" {} ''
    mkdir -p "$out"
    printf 'mounted\n' > "$out/value"
  '';
in {
  guest-workflow = harnesses.wasixShell {
    name = "bash-guest-workflow";
    shell = commands.bash;
    commands = [commands.cat commands.curl commands.sleep];
    host = {
      packages = [pkgs.python3];
      setup = ''
        mkdir -p "$TMPDIR/server"
        printf 'served\n' > "$TMPDIR/server/value"
        python3 -m http.server 18080 --bind 127.0.0.1 --directory "$TMPDIR/server" > "$TMPDIR/server.log" 2>&1 &
        server_pid=$!
        export TEST_ENDPOINT=http://127.0.0.1:18080/value
      '';
      teardown = ''
        kill "$server_pid"
        wait "$server_pid" || true
      '';
    };
    forwardEnv = ["TEST_ENDPOINT"];
    capabilities.network = true;
    mounts = [
      {
        source = fixture;
        target = "/fixtures";
      }
    ];
    script = ''
      test "$(cat /fixtures/value)" = mounted
      attempt=0
      until response=$(curl -fsS "$TEST_ENDPOINT"); do
        attempt=$((attempt + 1))
        test "$attempt" -lt 10
        sleep 1
      done
      test "$response" = served
    '';
  };
}
