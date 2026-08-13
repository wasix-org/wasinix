{
  pkgs,
  wasmerPkgs,
  testLib,
  helpers,
}: let
  inherit (helpers) gitSetup;
in {
  clone-local = testLib.mkWasixRun {
    name = "clone-local";
    wasixPkgs = [wasmerPkgs.git];
    script = ''
      ${gitSetup}
      mkdir source
      cd source
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      cd ..
      git clone source cloned
      cat cloned/hello.txt
    '';
  };

  push-local = testLib.mkWasixRun {
    name = "push-local";
    nativePkgs = [pkgs.git];
    wasixPkgs = [wasmerPkgs.git];
    script = ''
      ${gitSetup}
      ${pkgs.git}/bin/git init --bare --initial-branch=main remote.git
      mkdir work && cd work
      git init
      git remote add origin "$WASIX_TEST_ROOT/remote.git"
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      git push origin main
      cd ..
      git clone "$WASIX_TEST_ROOT/remote.git" cloned
      cat cloned/hello.txt
      cd work
      echo "world" >> hello.txt
      git add .
      git commit -m "second commit"
      git push origin main
      cd ../cloned
      git pull
      cat hello.txt
    '';
  };
}
