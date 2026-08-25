{
  pkgs,
  entry,
  harnesses,
  helpers,
}: let
  inherit (helpers) gitSetup setupNativeRemote startLighttpdHttp startLighttpdHttps;
in {
  clone-http = harnesses.hostShell {
    name = "clone-http";
    hostPackages = [pkgs.git pkgs.lighttpd];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttp {}}
      git clone http://127.0.0.1:8765/git-http-backend/remote.git cloned
      cat cloned/hello.txt
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

  push-http = harnesses.hostShell {
    name = "push-http";
    hostPackages = [pkgs.git pkgs.lighttpd];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttp {receivePack = true;}}
      git clone http://127.0.0.1:8765/git-http-backend/remote.git work
      cd work
      echo "world" >> hello.txt
      git add .
      git commit -m "second commit"
      git push origin main
      ${pkgs.lib.getExe pkgs.git} -C ../repos/remote.git log --oneline
    '';
  };

  clone-https = harnesses.hostShell {
    name = "clone-https";
    hostPackages = [pkgs.git pkgs.lighttpd pkgs.openssl];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttps {}}
      git clone https://127.0.0.1:8766/git-http-backend/remote.git cloned
      cat cloned/hello.txt
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

  push-https = harnesses.hostShell {
    name = "push-https";
    hostPackages = [pkgs.git pkgs.lighttpd pkgs.openssl];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttps {receivePack = true;}}
      git clone https://127.0.0.1:8766/git-http-backend/remote.git work
      cd work
      echo "world" >> hello.txt
      git add .
      git commit -m "second commit"
      git push origin main
      ${pkgs.lib.getExe pkgs.git} -C ../repos/remote.git log --oneline
    '';
  };
}
