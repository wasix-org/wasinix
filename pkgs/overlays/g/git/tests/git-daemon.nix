{
  commands,
  pkgs,
  entry,
  harnesses,
  helpers,
}: let
  inherit (helpers) gitSetup;
in {
  clone-net = harnesses.wasixShell {
    name = "clone-net";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
    runtime.network = true;
    host = {
      packages = [pkgs.git];
      setup = ''
        ${gitSetup}
        mkdir source && cd source
        git init
        echo "hello" > hello.txt
        git add .
        git commit -m "initial commit"
        cd ..
        ${pkgs.lib.getExe pkgs.git} daemon --base-path=. --export-all --reuseaddr --port=9418 &
        server_pid=$!
        sleep 1
      '';
      teardown = ''
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
      '';
    };
    script = ''
      git clone git://127.0.0.1:9418/source cloned
      cat cloned/hello.txt
    '';
  };

  fetch-net = harnesses.hostShell {
    name = "fetch-net";
    hostPackages = [pkgs.git];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      mkdir source && cd source
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      cd ..
      ${pkgs.lib.getExe pkgs.git} daemon --base-path=. --export-all --reuseaddr --port=9418 &
      sleep 1
      git clone git://127.0.0.1:9418/source cloned
      echo "world" >> source/hello.txt
      ${pkgs.lib.getExe pkgs.git} -C source add .
      ${pkgs.lib.getExe pkgs.git} -C source commit -m "second commit"
      cd cloned
      git fetch origin
      git --no-pager log --oneline origin/main
    '';
  };

  push-net = harnesses.wasixShell {
    name = "push-net";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
    runtime.network = true;
    host = {
      packages = [pkgs.git];
      setup = ''
        ${gitSetup}
        ${pkgs.lib.getExe pkgs.git} init --bare remote.git
        ${pkgs.lib.getExe pkgs.git} daemon --base-path=. --enable=receive-pack \
          --export-all --reuseaddr --port=9418 &
        server_pid=$!
        sleep 1
      '';
      teardown = ''
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
      '';
    };
    script = ''
      mkdir work && cd work
      git init
      git remote add origin git://127.0.0.1:9418/remote.git
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      git push origin main
      cd ..
      git clone git://127.0.0.1:9418/remote.git cloned
      cat cloned/hello.txt
    '';
  };

  pull-net = harnesses.hostShell {
    name = "pull-net";
    hostPackages = [pkgs.git];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      mkdir source && cd source
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      cd ..
      ${pkgs.lib.getExe pkgs.git} daemon --base-path=. --export-all --reuseaddr --port=9418 &
      sleep 1
      git clone git://127.0.0.1:9418/source cloned
      cat cloned/hello.txt
      echo "world" >> source/hello.txt
      ${pkgs.lib.getExe pkgs.git} -C source add .
      ${pkgs.lib.getExe pkgs.git} -C source commit -m "second commit"
      cd cloned
      git pull
      cat hello.txt
    '';
  };
}
