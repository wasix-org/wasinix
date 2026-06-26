{
  pkgs,
  wasmerPkgs,
  testLib,
  helpers,
}: let
  inherit (helpers) gitSetup;
in {
  clone-net = testLib.mkWasixRun {
    name = "clone-net";
    nativePkgs = [pkgs.git];
    wasixPkgs = [wasmerPkgs.git];
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      mkdir source && cd source
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      cd ..
      ${pkgs.git}/bin/git daemon --base-path=. --export-all --reuseaddr --port=9418 &
      sleep 1
      git clone git://127.0.0.1:9418/source cloned
      cat cloned/hello.txt
    '';
  };

  fetch-net = testLib.mkWasixRun {
    name = "fetch-net";
    nativePkgs = [pkgs.git];
    wasixPkgs = [wasmerPkgs.git];
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      mkdir source && cd source
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      cd ..
      ${pkgs.git}/bin/git daemon --base-path=. --export-all --reuseaddr --port=9418 &
      sleep 1
      git clone git://127.0.0.1:9418/source cloned
      echo "world" >> source/hello.txt
      ${pkgs.git}/bin/git -C source add .
      ${pkgs.git}/bin/git -C source commit -m "second commit"
      cd cloned
      git fetch origin
      git --no-pager log --oneline origin/main
    '';
  };

  push-net = testLib.mkWasixRun {
    name = "push-net";
    nativePkgs = [pkgs.git];
    wasixPkgs = [wasmerPkgs.git];
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      ${pkgs.git}/bin/git init --bare remote.git
      ${pkgs.git}/bin/git daemon --base-path=. --enable=receive-pack \
        --export-all --reuseaddr --port=9418 &
      sleep 1
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

  pull-net = testLib.mkWasixRun {
    name = "pull-net";
    nativePkgs = [pkgs.git];
    wasixPkgs = [wasmerPkgs.git];
    wasmerArgs = ["--net"];
    script = ''
      ${gitSetup}
      mkdir source && cd source
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      cd ..
      ${pkgs.git}/bin/git daemon --base-path=. --export-all --reuseaddr --port=9418 &
      sleep 1
      git clone git://127.0.0.1:9418/source cloned
      cat cloned/hello.txt
      echo "world" >> source/hello.txt
      ${pkgs.git}/bin/git -C source add .
      ${pkgs.git}/bin/git -C source commit -m "second commit"
      cd cloned
      git pull
      cat hello.txt
    '';
  };
}
