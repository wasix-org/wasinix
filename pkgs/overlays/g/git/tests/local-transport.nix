{
  commands,
  pkgs,
  entry,
  harnesses,
  helpers,
}: let
  inherit (helpers) assertFile gitSetup;
in {
  clone-local = harnesses.wasixShell {
    name = "clone-local";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
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
      ${assertFile "cloned/hello.txt" "hello"}
    '';
  };

  push-local = harnesses.wasixShell {
    name = "push-local";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
    host = {
      packages = [pkgs.git];
      setup = ''
        ${gitSetup}
        ${pkgs.lib.getExe pkgs.git} init --bare --initial-branch=main remote.git
      '';
    };
    script = ''
      mkdir work && cd work
      git init
      git remote add origin "$WASIX_TEST_ROOT/remote.git"
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      git push origin main
      cd ..
      git clone "$WASIX_TEST_ROOT/remote.git" cloned
      ${assertFile "cloned/hello.txt" "hello"}
      cd work
      echo "world" >> hello.txt
      git add .
      git commit -m "second commit"
      git push origin main
      cd ../cloned
      git pull
      ${assertFile "hello.txt" ''          hello
          world''}
    '';
  };
}
