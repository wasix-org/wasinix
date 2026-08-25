# pandoc-cli with the lua/server engines off (their deps don't cross-compile).
# -f-lua/-f-server disable the cabal flags, but nixpkgs' deps come from hackage2nix
# (not the flags), so also filter the lua/server trees by name. GHC installs the
# exe as bin/pandoc.wasm; nixpkgs' pandoc-cli override symlinks bin/pandoc-server
# -> bin/pandoc (dangles, server disabled), so drop postInstall.
{
  hprev,
  toolchain,
  lib,
  ...
}: let
  inherit (import ./lib/deps.nix) dropDeps;
  hs = toolchain.haskell.lib;
  dropLuaServer = deps:
    dropDeps [
      "pandoc-lua-engine"
      "pandoc-server"
      "pandoc-lua-marshal"
      "lua"
      "lpeg"
      "isocline"
      "readline"
      "ncurses"
      "warp"
      "servant-server"
      "network"
      "http2"
      "iproute"
      "recv"
      "simple-sendfile"
      "http-semantics"
      "http-api-data"
      "servant"
    ]
    # hslua-* and wai-* are whole families; drop by prefix.
    (builtins.filter (d: let n = d.pname or ""; in !(lib.hasPrefix "hslua" n || lib.hasPrefix "wai" n)) deps);
in
  hs.overrideCabal (hs.appendConfigureFlags hprev.pandoc-cli ["-f-lua" "-f-server"]) (old: {
    patches = (old.patches or []) ++ [./patches/pandoc-cli/wasi-no-threaded.patch];
    executableHaskellDepends = dropLuaServer (old.executableHaskellDepends or []);
    libraryHaskellDepends = dropLuaServer (old.libraryHaskellDepends or []);
    postInstall = "";
  })
