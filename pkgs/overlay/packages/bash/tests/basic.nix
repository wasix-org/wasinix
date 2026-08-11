{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: let
  bashPkg = wasmerPkgs.bash;
in {
  # Core shell behavior: conditionals, loops, arrays, functions, pattern matching.
  core = testLib.mkWasixRun {
    name = "bash-core";
    wasixPkgs = [bashPkg];
    script = ''
      set +e
      bash -c 'exit 7'
      status=$?
      set -e
      if [ "$status" -ne 7 ]; then
        echo "exit returned $status"
        exit 1
      fi

      bash -c '[ x = x ]'
      bash -c '[ 3 -gt 2 ]'
      bash -c 'i=3; while [ "$i" -gt 0 ]; do i=$((i - 1)); done; echo loop-ok'
      bash -c 'v=hi; [ "$v" = hi ]; echo "$v"'
      bash -c 'shopt -s extglob; [[ foobar == @(foo|foobar) ]]; [[ abc == a?c ]]; echo extglob-ok'
      bash -c 'arr=(zero one two); [ "''${arr[2]}" = two ]; echo "''${arr[*]}"'
      bash -c 'declare -A map=([left]=right); [ "''${map[left]}" = right ]; echo "''${!map[@]}"'
      bash -c 'f() { local x=7; out=$x; }; out=; f; [ "$out" = 7 ]'
      bash -c 'printf -v out "%s-%s" left right; [ "$out" = left-right ]; echo "$out"'
      bash -c 'case abc in a?c) echo case-ok ;; *) exit 1 ;; esac'
      bash -c '[[ 123 =~ ^[0-9]+$ ]]; echo regex-ok'
    '';
  };

  # test/[ returns its result through setjmp/longjmp; off-EH must yield ordinary
  # statuses where EH profiles crash with an uncaught exception. Covers empty
  # tests, unquoted-empty-var collapse, and syntax errors (deep-frame longjmp).
  conditionals = testLib.mkWasixRun {
    name = "bash-conditionals";
    wasixPkgs = [bashPkg];
    script = ''
      check() { # check <expected-status> <script>
        local want=$1 got
        set +e
        bash -c "$2" >/dev/null 2>&1
        got=$?
        set -e
        if [ "$got" -ne "$want" ]; then
          echo "FAIL: '$2' -> $got, expected $want"
          exit 1
        fi
      }
      check 1 '[ ]'
      check 0 'x=; if [ $x ]; then exit 1; else exit 0; fi'
      check 2 '[ x'
      check 2 '[ a b c ]'
      check 2 '[ -gt 2 ]'
      check 0 '[ x = x ]'
      check 1 '[ x = y ]'
      # set -e must observe the syntax-error status, not crash through it.
      check 2 'set -e; [ a b c ]; echo unreached'
      echo conditionals-ok
    '';
  };

  # Fork-backed features: command substitution, pipelines, subshells.
  fork = testLib.mkWasixRun {
    name = "bash-fork";
    wasixPkgs = [bashPkg];
    script = ''
      bash -c 'v=$(echo hi); [ "$v" = hi ]; echo "$v"'
      bash -c 'printf "a\nb\n" | while read line; do echo "$line"; done'
      bash -c '(exit 3); echo "subshell-status:$?"'
    '';
  };

  # Interactive mode: readline must initialize and run commands. Feed a line on
  # stdin (a pipe, not a tty); -i forces interactive, EOF exits.
  interactive = testLib.mkWasixRun {
    name = "bash-interactive";
    wasixPkgs = [bashPkg];
    script = ''
      out=$(printf 'echo readline-live-$((6 * 7))\n' | bash -i 2>&1)
      case "$out" in
        *readline-live-42*) echo interactive-ok ;;
        *) echo "interactive mode failed: $out"; exit 1 ;;
      esac
    '';
  };

  # COLUMNS/LINES come from TIOCGWINSZ, which wasix-libc answers from
  # __wasi_tty_get. --noediting keeps readline from setting them instead, so
  # only bash's own winsize path can satisfy this.
  winsize = testLib.mkWasixRun {
    name = "bash-winsize";
    wasixPkgs = [bashPkg];
    nativePkgs = [pkgs.python3];
    script = ''
      cat > pty-size.py <<'PYEOF'
      import os, pty, select, struct, sys, fcntl, termios

      pid, fd = pty.fork()
      if pid == 0:
          os.execvp(sys.argv[1], sys.argv[1:])
      fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 41, 137, 0, 0))
      os.write(fd, b"echo MARK COLUMNS=$COLUMNS LINES=$LINES\nexit\n")
      out = b""
      while select.select([fd], [], [], 60)[0]:
          try:
              chunk = os.read(fd, 4096)
          except OSError:
              break
          if not chunk:
              break
          out += chunk
      os.waitpid(pid, 0)
      sys.stdout.write(out.decode(errors="replace"))
      PYEOF
      out=$(python3 pty-size.py bash --noediting -i 2>&1)
      case "$out" in
        *"MARK COLUMNS=137 LINES=41"*) echo winsize-ok ;;
        *) echo "window size not picked up: $out"; exit 1 ;;
      esac
    '';
  };

  # The sh command atom shares bash's module, and dependents exec it by that
  # name, so argv[0] must arrive as sh. PATH must reach the /bin where wasmer
  # mounts a webc's dependency commands.
  sh = testLib.mkWasixRun {
    name = "bash-sh";
    wasixPkgs = [bashPkg];
    script = ''
      out=$(sh -c 'echo "argv0=$0 path=$PATH"')
      if [ "$out" != "argv0=sh path=/bin:/usr/bin" ]; then
        echo "unexpected sh invocation: $out"
        exit 1
      fi
      echo sh-ok
    '';
  };
}
