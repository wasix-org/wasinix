# The evaluator under wasmer, checked against the native nix of the same
# version. `--store dummy://` keeps the store in memory, so nothing here needs
# a store directory and nothing builds.
{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: let
  wasix = [wasmerPkgs.nix];

  # Two differences that aren't about the evaluator:
  #  - under wasmer isatty(1) is true even when stdout is a file, so nix's
  #    logger draws its progress line with CSI escapes (WASIX-TODO.md);
  #  - the native run is sandboxed and reports itself offline, while the wasi
  #    build has no getifaddrs and always assumes it is online.
  normalizeLog = pkgs.writeShellScript "normalize-nix-log" ''
    ${pkgs.gnused}/bin/sed -e 's/\r//g' -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
      -e "s|copying '[^']*' to the store||" \
      | ${pkgs.gnugrep}/bin/grep -v "you don't have Internet access" || true
  '';

  # nix-command is experimental in a release build, and the store has to be one
  # that needs no filesystem.
  cmp = name: expr:
    testLib.mkScriptComparison {
      name = "nix-${name}";
      nativePkgs = [pkgs.nix];
      wasixPkgs = wasix;
      normalize = normalizeLog;
      script = ''
        nix --extra-experimental-features nix-command --store dummy:// \
          eval --expr ${pkgs.lib.escapeShellArg expr}
      '';
    };
in {
  version = testLib.mkWasixRun {
    name = "nix-version";
    wasixPkgs = wasix;
    script = "nix --version";
  };

  arithmetic = cmp "arithmetic" "builtins.foldl' (a: b: a + b * 2) 0 [1 2 3 4 5]";
  recursion = cmp "recursion" "let fib = n: if n < 2 then n else fib (n - 1) + fib (n - 2); in map fib [10 15 20]";
  strings = cmp "strings" ''let s = "a-b-c"; in { j = builtins.concatStringsSep "/" (builtins.filter builtins.isString (builtins.split "-" s)); u = builtins.substring 2 3 s; }'';
  # the <regex> calls that only compile untouched against libstdc++
  regex = cmp "regex" ''builtins.match "([a-z]+)-([0-9.]+)" "hello-1.2.3"'';
  json = cmp "json" ''builtins.fromJSON "{\"a\":[1,2,{\"b\":true}]}"'';
  # toml11
  toml = cmp "toml" ''builtins.fromTOML "x = 1\ny = [1, 2]"'';
  # openssl + libblake3
  hashes = cmp "hashes" ''builtins.mapAttrs (a: _: builtins.hashString a "hello") { md5 = 1; sha1 = 1; sha256 = 1; sha512 = 1; }'';

  # Store writes run the NAR serializer through its Boost coroutine; a matching
  # store path means the bytes it produced are identical.
  store-path = testLib.mkScriptComparison {
    name = "nix-store-path";
    nativePkgs = [pkgs.nix];
    wasixPkgs = wasix;
    normalize = normalizeLog;
    script = ''
      mkdir -p tree/sub
      echo hello > tree/a.txt
      echo world > tree/sub/b.txt
      nix --extra-experimental-features nix-command --store 'dummy://?read-only=false' \
        eval --impure --expr "builtins.path { path = ./tree; name = \"tree\"; }"
    '';
  };
}
