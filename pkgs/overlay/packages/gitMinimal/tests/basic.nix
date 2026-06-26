{
  pkgs,
  wasmerPkgs,
  testLib,
  helpers,
}: let
  inherit (helpers) gitNative normalizeGitPaths gitSetup;
in {
  version = testLib.mkWasixRun {
    name = "version";
    wasixPkgs = [wasmerPkgs.git];
    script = "git --version";
  };

  version-compare = testLib.mkScriptComparison {
    name = "version";
    nativePkgs = [gitNative];
    wasixPkgs = [wasmerPkgs.git];
    normalize = normalizeGitPaths;
    script = "git --version";
  };

  workflow = testLib.mkWasixRun {
    name = "workflow";
    wasixPkgs = [wasmerPkgs.git];
    script = ''
      ${gitSetup}
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      git --no-pager log --oneline
    '';
  };

  workflow-compare = testLib.mkScriptComparison {
    name = "workflow";
    nativePkgs = [gitNative];
    wasixPkgs = [wasmerPkgs.git];
    normalize = normalizeGitPaths;
    script = ''
      ${gitSetup}
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      echo "world" >> hello.txt
      git add .
      git commit -m "second commit"
      git --no-pager log --oneline
    '';
  };

  diff = testLib.mkWasixRun {
    name = "diff";
    wasixPkgs = [wasmerPkgs.git];
    script = ''
      ${gitSetup}
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      echo "world" >> hello.txt
      git --no-pager diff hello.txt
      git add .
      git commit -m "second commit"
      git --no-pager diff HEAD~1 HEAD
    '';
  };

  diff-compare = testLib.mkScriptComparison {
    name = "diff";
    nativePkgs = [gitNative];
    wasixPkgs = [wasmerPkgs.git];
    normalize = normalizeGitPaths;
    script = ''
      ${gitSetup}
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      echo "world" >> hello.txt
      git --no-pager diff hello.txt
      git add .
      git commit -m "second commit"
      git --no-pager diff HEAD~1 HEAD
    '';
  };

  branch = testLib.mkWasixRun {
    name = "branch";
    wasixPkgs = [wasmerPkgs.git];
    script = ''
      ${gitSetup}
      git init
      echo "hello" > hello.txt
      git add .
      git commit -m "initial commit"
      git checkout -b feature
      echo "feature content" > feature.txt
      git add .
      git commit -m "add feature"
      git checkout main
      git merge --no-edit feature
      git --no-pager log --oneline
      cat feature.txt
    '';
  };
}
