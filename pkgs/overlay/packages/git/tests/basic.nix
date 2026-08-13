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

  # -P needs USE_LIBPCRE2; without it git fails the command outright.
  grep-pcre = testLib.mkWasixRun {
    name = "grep-pcre";
    wasixPkgs = [wasmerPkgs.git];
    script = ''
      ${gitSetup}
      git init
      printf 'alpha\nbeta\n' > words.txt
      git add .
      git commit -m "words"
      out=$(git --no-pager grep -P 'al\w+ha')
      if [ "$out" != "words.txt:alpha" ]; then
        echo "unexpected grep -P output: $out"
        exit 1
      fi
    '';
  };

  # A shell subcommand: git-filter-branch runs through /bin/bash, calls the
  # coreutils and sed the webc mounts by store path, and resolves the filter's
  # own sed from PATH.
  filter-branch = testLib.mkWasixRun {
    name = "filter-branch";
    wasixPkgs = [wasmerPkgs.git];
    script = ''
      ${gitSetup}
      git init
      echo hello > hello.txt
      git add .
      git commit -m "before"
      FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
        --msg-filter 'sed s/before/after/' HEAD
      out=$(git --no-pager log --format=%s)
      if [ "$out" != "after" ]; then
        echo "message not rewritten: $out"
        exit 1
      fi
    '';
  };

  # The editor is nano's command atom, mounted at /bin by the webc dependency.
  # The alias runs it through git's own shell, the way `git commit` would.
  editor = testLib.mkWasixRun {
    name = "editor";
    wasixPkgs = [wasmerPkgs.git];
    script = ''
      ${gitSetup}
      editor=$(git var GIT_EDITOR)
      if [ "$editor" != "/bin/nano" ]; then
        echo "unexpected editor: $editor"
        exit 1
      fi
      out=$(git -c alias.editor-version='!/bin/nano --version' editor-version)
      case "$out" in
        *"GNU nano"*) echo editor-ok ;;
        *) echo "editor did not run: $out"; exit 1 ;;
      esac
    '';
  };
}
