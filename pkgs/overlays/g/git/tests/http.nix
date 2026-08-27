{
  commands,
  pkgs,
  entry,
  harnesses,
  helpers,
}: let
  inherit (helpers) assertFile gitSetup setupNativeRemote startLighttpdHttp startLighttpdHttps;
in {
  clone-http = harnesses.wasixShell {
    name = "clone-http";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
    runtime.network = true;
    host = {
      packages = [pkgs.git pkgs.lighttpd];
      setup = ''
        ${gitSetup}
        ${setupNativeRemote}
        ${startLighttpdHttp {}}
      '';
      teardown = ''
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
      '';
    };
    script = ''
      git clone http://127.0.0.1:8765/git-http-backend/remote.git cloned
      ${assertFile "cloned/hello.txt" "hello"}
    '';
  };

  fetch-http = harnesses.hostShell {
    name = "fetch-http";
    hostPackages = [pkgs.git pkgs.lighttpd];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttp {}}
      git clone http://127.0.0.1:8765/git-http-backend/remote.git cloned
      echo "world" >> source/hello.txt
      ${pkgs.lib.getExe pkgs.git} -C source add .
      ${pkgs.lib.getExe pkgs.git} -C source commit -m "second commit"
      ${pkgs.lib.getExe pkgs.git} -C source push ../repos/remote.git HEAD:main
      cd cloned
      git fetch origin
      git --no-pager log --oneline origin/main
    '';
  };

  push-http = harnesses.wasixShell {
    name = "push-http";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
    runtime.network = true;
    host = {
      packages = [pkgs.git pkgs.lighttpd];
      setup = ''
        ${gitSetup}
        ${setupNativeRemote}
        ${startLighttpdHttp {receivePack = true;}}
      '';
      teardown = ''
        verification_status=0
        ${pkgs.lib.getExe pkgs.git} -C repos/remote.git log --oneline || verification_status=$?
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        test "$verification_status" -eq 0
      '';
    };
    script = ''
      git clone http://127.0.0.1:8765/git-http-backend/remote.git work
      cd work
      echo "world" >> hello.txt
      git add .
      git commit -m "second commit"
      git push origin main
    '';
  };

  clone-https = harnesses.wasixShell {
    name = "clone-https";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
    runtime.network = true;
    host = {
      packages = [pkgs.git pkgs.lighttpd pkgs.openssl];
      setup = ''
        ${gitSetup}
        ${setupNativeRemote}
        ${startLighttpdHttps {}}
      '';
      teardown = ''
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
      '';
    };
    script = ''
      git config --global http.sslCAInfo "$WASIX_TEST_ROOT/ca.crt"
      git clone https://127.0.0.1:8766/git-http-backend/remote.git cloned
      ${assertFile "cloned/hello.txt" "hello"}
    '';
  };

  fetch-https = harnesses.hostShell {
    name = "fetch-https";
    hostPackages = [pkgs.git pkgs.lighttpd pkgs.openssl];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttps {}}
      git clone https://127.0.0.1:8766/git-http-backend/remote.git cloned
      echo "world" >> source/hello.txt
      ${pkgs.lib.getExe pkgs.git} -C source add .
      ${pkgs.lib.getExe pkgs.git} -C source commit -m "second commit"
      ${pkgs.lib.getExe pkgs.git} -C source push ../repos/remote.git HEAD:main
      cd cloned
      git fetch origin
      git --no-pager log --oneline origin/main
    '';
  };

  push-https = harnesses.wasixShell {
    name = "push-https";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
    runtime.network = true;
    host = {
      packages = [pkgs.git pkgs.lighttpd pkgs.openssl];
      setup = ''
        ${gitSetup}
        ${setupNativeRemote}
        ${startLighttpdHttps {receivePack = true;}}
      '';
      teardown = ''
        verification_status=0
        ${pkgs.lib.getExe pkgs.git} -C repos/remote.git log --oneline || verification_status=$?
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        test "$verification_status" -eq 0
      '';
    };
    script = ''
      git config --global http.sslCAInfo "$WASIX_TEST_ROOT/ca.crt"
      git clone https://127.0.0.1:8766/git-http-backend/remote.git work
      cd work
      echo "world" >> hello.txt
      git add .
      git commit -m "second commit"
      git push origin main
    '';
  };
}
