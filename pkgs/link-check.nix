# Link check for a library with no upstream suite: link all
# objects, or a declared consumer for a header-only library, and run it.
# This catches undefined symbols that surface only at link or instantiation.
# Build-once / run-many like the real checks; never counted as a suite.
{
  lib,
  pkgs,
  helpers,
  wasixRun,
}: let
  xverdict = import ./lib/xverdict.nix;

  runVerdict = name: spec: cmd: let
    timeout = spec.timeout or 1800;
    verdict = xverdict {
      inherit name;
      expectFail = spec.expectFail or null;
      broken = spec.broken or null;
      succeed = ":";
      failHard = ''cat "$_log" >&2; exit 1'';
    };
  in ''
    _log="$NIX_BUILD_TOP/check.log"
    set +e
    timeout --foreground ${toString timeout} ${cmd} 2>&1 | tee "$_log"
    _rc=''${PIPESTATUS[0]}
    set -e
    mkdir -p "$out"
    cp "$_log" "$out/check.log" 2>/dev/null || true
    if [ "$_rc" -eq 124 ]; then
      echo "TIMEOUT: '${name}' exceeded ${toString timeout}s" >&2
      ${lib.optionalString ((spec.expectFail or null) != null) ''exit 1''}
    fi
    if [ "$_rc" -eq 0 ]; then
      ${verdict.onCheckPass}
    else
      ${verdict.onCheckFail}
    fi
  '';

  # spec.pkgConfig overrides the pkg-config modules used for dependency
  # flags; spec.archives overrides the default of every shipped .a.
  linkBuild = name: drv: spec: profilePkgs:
    profilePkgs.stdenv.mkDerivation {
      pname = "${name}-link-check";
      version = "0";
      dontUnpack = true;
      nativeBuildInputs = [profilePkgs.buildPackages.pkg-config];
      # The package's own inputs too: its .pc Requires.private names sibling
      # modules, and without them in scope pkg-config resolves nothing and
      # the whole-archive link fails on the dependency's symbols.
      buildInputs =
        [drv]
        ++ (drv.buildInputs or [])
        ++ (drv.propagatedBuildInputs or []);
      # One module per archive, deduped by realpath since a package can ship
      # the same archive under several names, and genuine variants share
      # helper symbols that collide in a single module; sibling archives are
      # offered as ordinary inputs because archives routinely depend on each
      # other, and only the one under test needs pulling in whole. Dependency
      # flags come from the package's own .pc files rather than a module name
      # guessed from pname; the two rarely match. Each archive tries CC then
      # CXX, since a C++ archive needs the C++ driver for libc++/cxxabi and C
      # links under either, and whole-archive before plain: whole resolves
      # every object, the real check, while plain still proves a valid wasm
      # archive that instantiates when an optional dependency absent from
      # pkg-config blocks the whole link. The mode used is logged so a
      # weakened check stays visible.
      buildPhase = ''
        ${
          if spec ? source
          then ''
            cat > main.cpp <<'MAIN'
            ${spec.source}
            MAIN
            mkdir -p out
            "$CXX" main.cpp ${spec.extraLinkFlags or ""} -o "out/${name}.wasm"
            echo "linked ${name} [source/$(basename "$CXX")]"
          ''
          else ''
            cat > main.c <<'MAIN'
            int main(void) { return 0; }
            MAIN

            archives=$(${
              if spec ? archives
              then spec.archives
              else ''find -L ${lib.getLib drv} ${lib.getDev drv} -name '*.a' 2>/dev/null | xargs -r -n1 realpath | sort -u''
            })
            [ -n "$archives" ] || { echo "no static archives found for ${name}"; exit 1; }

            deps=""
            mods=${
              if spec ? pkgConfig
              then lib.escapeShellArg spec.pkgConfig
              else ''"$(find -L ${lib.getDev drv} ${lib.getLib drv} -name '*.pc' 2>/dev/null | xargs -r -n1 basename | sed 's/\.pc$//' | sort -u | tr '\n' ' ')"''
            }
            for m in $mods; do
              if pkg-config --exists "$m" 2>/dev/null; then
                deps="$deps $(pkg-config --libs --static "$m")"
              fi
            done

            mkdir -p out
            n=0
            for a in $archives; do
              base=$(basename "$a" .a)
              siblings=""
              for s in $archives; do [ "$s" = "$a" ] || siblings="$siblings $s"; done
              linked=""
              for mode in whole plain; do
                case "$mode" in
                  whole) aflags="-Wl,--whole-archive $a -Wl,--no-whole-archive" ;;
                  plain) aflags="$a" ;;
                esac
                for drv_cc in "$CC" "$CXX"; do
                  if $drv_cc main.c $aflags $siblings $deps ${spec.extraLinkFlags or ""} -o "out/$base.wasm" 2>"$base.err"; then
                    linked="$mode/$(basename "$drv_cc")"
                    break 2
                  fi
                done
              done
              if [ -n "$linked" ]; then
                echo "linked $base [$linked]"
                n=$((n + 1))
              else
                echo "FAILED to link $base" >&2
                cat "$base.err" >&2
                exit 1
              fi
            done
            echo "linked $n module(s)"
          ''
        }
      '';
      installPhase = ''
        mkdir -p "$out"
        cp out/*.wasm "$out/"
      '';
      passthru.wasix.supportedProfiles = (helpers.wasixMetaOf drv).supportedProfiles or null;
    };

  runLinkCheck = name: linked: spec:
    pkgs.runCommand name {
      nativeBuildInputs = [wasixRun.run];
    } (''
        export HOME="$NIX_BUILD_TOP/home"
        mkdir -p "$HOME"
      ''
      + runVerdict name spec ''
        bash -c 'for m in ${linked}/*.wasm; do echo "run $(basename "$m")"; wasix-run "$m" || exit 1; done'
      '');
in {
  linkFor = profilePkgs: drv: spec: let
    name = "${lib.getName drv}-link-check";
  in
    runLinkCheck name (linkBuild name drv spec profilePkgs) spec;
}
