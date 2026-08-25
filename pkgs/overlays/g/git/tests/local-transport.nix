{
  pkgs,
  entry,
  harnesses,
  helpers,
}: let
  inherit (helpers) gitSetup;
in {
  clone-local = harnesses.hostShell {
    name = "clone-local";
    wasixCommands = builtins.attrValues entry.commands;
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

  push-local = harnesses.hostShell {
    name = "push-local";
    hostPackages = [pkgs.git];
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      ${gitSetup}
      ${pkgs.lib.getExe pkgs.git} init --bare --initial-branch=main remote.git
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
