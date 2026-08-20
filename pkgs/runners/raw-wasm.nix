# `wasix-run <program> [args...]`: run a wasm binary under wasmer with the
# build tree identity-mounted, so paths recorded at build time resolve.
# Env knobs: WASIX_WASMER (runtime), WASIX_RUN_ENV / WASIX_RUN_ENV_ALL
# (guest env), WASIX_RUN_FLAGS (extra wasmer flags).
{pkgs}: let
  coreutils = pkgs.buildPackages.coreutils;

  # No wasmer in the closure: build artifacts bake this launcher in (cmake's
  # CMAKE_CROSSCOMPILING_EMULATOR, cargo runners, meson's exe_wrapper), so a
  # wasmer bump rebuilds nothing; the runtime resolves from $WASIX_WASMER or
  # PATH at exec time. Wasm is recognised by magic, bare or behind the
  # shebang line the patched runtime skips; exec'ing a shebanged module would
  # re-enter this launcher forever, and everything non-wasm is exec'd unchanged.
  # Mounts keep guest paths equal to host paths, skipping nested dirs since
  # wasmer rejects overlapping volumes. WASIX_RUN_ENV_ALL forwards the whole
  # exported environment, because a suite's preCheck can export variables no
  # allowlist could anticipate: env -0 preserves values with newlines,
  # non-identifier names (bash's exported functions) are dropped, and so are
  # blank values, since wasmer rejects `--env KEY=` for empty and
  # whitespace-only values.
  unbound = pkgs.buildPackages.writeShellScriptBin "wasix-run" ''
    set -o pipefail

    prog=''${1-}
    if [ -z "$prog" ]; then
      echo "wasix-run: no program given" >&2
      exit 2
    fi
    shift

    _magic_at() { ${pkgs.lib.getExe' coreutils "od"} -An -tx1 -N4 -j "$1" "$prog" 2>/dev/null | ${pkgs.lib.getExe' coreutils "tr"} -d ' \n'; }
    is_wasm=no
    if [ "$(_magic_at 0)" = "0061736d" ]; then
      is_wasm=yes
    elif [ "$(${pkgs.lib.getExe' coreutils "od"} -An -tx1 -N2 "$prog" 2>/dev/null | ${pkgs.lib.getExe' coreutils "tr"} -d ' \n')" = "2321" ]; then
      _sl=$(${pkgs.lib.getExe' coreutils "head"} -1 "$prog" 2>/dev/null | ${pkgs.lib.getExe' coreutils "wc"} -c)
      [ "$(_magic_at "$_sl")" = "0061736d" ] && is_wasm=yes
    fi
    if [ "$is_wasm" != yes ]; then
      exec "$prog" "$@"
    fi

    wasmer=''${WASIX_WASMER-}
    if [ -z "$wasmer" ]; then
      wasmer=$(command -v wasmer || true)
    fi
    if [ -z "$wasmer" ]; then
      echo "wasix-run: no runtime (set \$WASIX_WASMER or put wasmer on PATH)" >&2
      exit 127
    fi

    flags=()
    mounted=()
    _mount() {
      local d=$1 m
      [ -n "$d" ] && [ -d "$d" ] || return 0
      for m in ''${mounted[@]+"''${mounted[@]}"}; do
        case "$d" in "$m" | "$m"/*) return 0 ;; esac
      done
      mounted+=("$d")
      flags+=(--volume "$d:$d")
    }
    _mount "''${NIX_BUILD_TOP-}"
    _mount /nix/store
    _mount "$PWD"
    _mount "''${HOME-}"

    if [ -n "''${WASIX_RUN_ENV_ALL-}" ]; then
      while IFS= read -r -d "" _kv; do
        _v=''${_kv%%=*}
        case "$_v" in "" | [0-9]* | *[!A-Za-z0-9_]*) continue ;; esac
        case "''${_kv#*=}" in *[![:space:]]*) ;; *) continue ;; esac
        flags+=(--env "$_kv")
      done < <(${pkgs.lib.getExe' coreutils "env"} -0)
    else
      for v in HOME TMPDIR TERM TZ LANG LC_ALL ''${WASIX_RUN_ENV-}; do
        val=$(${pkgs.lib.getExe' coreutils "printenv"} "$v") || continue
        case "$val" in *[![:space:]]*) ;; *) continue ;; esac
        flags+=(--env "$v=$val")
      done
    fi

    exec "$wasmer" run "''${flags[@]}" ''${WASIX_RUN_FLAGS-} --cwd "$PWD" "$prog" -- "$@"
  '';

  # Pair the launcher with a pinned runtime for run-only derivations.
  withRuntime = wasmer:
    pkgs.buildPackages.runCommand "wasix-run-${wasmer.version or "0"}" {
      nativeBuildInputs = [pkgs.buildPackages.makeWrapper];
      passthru = {
        stub = unbound;
        inherit wasmer;
      };
    } ''
      makeWrapper ${pkgs.lib.getExe unbound} "$out/bin/wasix-run" \
        --set WASIX_WASMER ${pkgs.lib.getExe wasmer}
    '';
in {
  inherit unbound withRuntime;
}
