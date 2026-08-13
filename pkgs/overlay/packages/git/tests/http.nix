{
  pkgs,
  wasmerPkgs,
  testLib,
  helpers,
}: let
  inherit (helpers) gitSetup setupNativeRemote startLighttpdHttp startLighttpdHttps;
in {
  clone-http = testLib.mkWasixRun {
    name = "clone-http";
    nativePkgs = [pkgs.git pkgs.lighttpd];
    wasixPkgs = [wasmerPkgs.git];
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttp {}}
      git clone http://127.0.0.1:8765/git-http-backend/remote.git cloned
      cat cloned/hello.txt
    '';
  };

  fetch-http = testLib.mkWasixRun {
    name = "fetch-http";
    nativePkgs = [pkgs.git pkgs.lighttpd];
    wasixPkgs = [wasmerPkgs.git];
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttp {}}
      git clone http://127.0.0.1:8765/git-http-backend/remote.git cloned
      echo "world" >> source/hello.txt
      ${pkgs.git}/bin/git -C source add .
      ${pkgs.git}/bin/git -C source commit -m "second commit"
      ${pkgs.git}/bin/git -C source push ../repos/remote.git HEAD:main
      cd cloned
      git fetch origin
      git --no-pager log --oneline origin/main
    '';
  };

  push-http = testLib.mkWasixRun {
    name = "push-http";
    nativePkgs = [pkgs.git pkgs.lighttpd];
    wasixPkgs = [wasmerPkgs.git];
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
      ${pkgs.git}/bin/git -C ../repos/remote.git log --oneline
    '';
  };

  clone-https = testLib.mkWasixRun {
    name = "clone-https";
    nativePkgs = [pkgs.git pkgs.lighttpd pkgs.openssl];
    wasixPkgs = [wasmerPkgs.git];
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttps {}}
      git clone https://127.0.0.1:8766/git-http-backend/remote.git cloned
      cat cloned/hello.txt
    '';
  };

  fetch-https = testLib.mkWasixRun {
    name = "fetch-https";
    nativePkgs = [pkgs.git pkgs.lighttpd pkgs.openssl];
    wasixPkgs = [wasmerPkgs.git];
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${setupNativeRemote}
      ${startLighttpdHttps {}}
      git clone https://127.0.0.1:8766/git-http-backend/remote.git cloned
      echo "world" >> source/hello.txt
      ${pkgs.git}/bin/git -C source add .
      ${pkgs.git}/bin/git -C source commit -m "second commit"
      ${pkgs.git}/bin/git -C source push ../repos/remote.git HEAD:main
      cd cloned
      git fetch origin
      git --no-pager log --oneline origin/main
    '';
  };

  push-https = testLib.mkWasixRun {
    name = "push-https";
    nativePkgs = [pkgs.git pkgs.lighttpd pkgs.openssl];
    wasixPkgs = [wasmerPkgs.git];
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
      ${pkgs.git}/bin/git -C ../repos/remote.git log --oneline
    '';
  };
}
