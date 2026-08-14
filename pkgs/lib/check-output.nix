# The `check` output: the package's own build captures its test tree where
# checkPhase would have run, so the suite compiles once and wasmer stays out
# of the build closure. pkgs/emulated-check.nix restores and runs it; see
# docs/architecture.md.
{
  lib,
  referenceScanner ? null,
  snapshotZstd ? null,
}: let
  # Broken or unevaluable check inputs cannot enter the cross build. Omitting
  # one leaves the suite to report the missing dependency.
  usable = lib.filter (
    i: let
      r = builtins.tryEval (
        i == null || !(i.meta.broken or false)
      );
    in
      r.success && r.value
  );

  snapshotEnvironment = ''
    {
      set +o
      shopt -p
      while IFS= read -r _wasix_snapshot_declaration; do
        _wasix_snapshot_fields="''${_wasix_snapshot_declaration#declare }"
        _wasix_snapshot_flags="''${_wasix_snapshot_fields%% *}"
        _wasix_snapshot_assignment="''${_wasix_snapshot_fields#* }"
        _wasix_snapshot_name="''${_wasix_snapshot_assignment%%=*}"
        case "$_wasix_snapshot_name" in
          BASH* | COMP_* | DIRSTACK | EPOCHREALTIME | EPOCHSECONDS | EUID | FUNCNAME | GROUPS | HISTCMD | HOSTNAME | LINENO | MACHTYPE | OLDPWD | OPTARG | OPTIND | OSTYPE | PIPESTATUS | PPID | PWD | RANDOM | SECONDS | SHELLOPTS | SHLVL | SRANDOM | TEMP | TEMPDIR | TMP | TMPDIR | UID | _ | _build_rel | _prebuild_rc | _wasix_snapshot_* | check | HOME | NIX_ATTRS_JSON_FILE | NIX_ATTRS_SH_FILE | NIX_BUILD_TOP)
            continue
            ;;
        esac
        case "$_wasix_snapshot_flags" in
          *r* | *n*) continue ;;
        esac
        printf 'declare -g %s\n' "''${_wasix_snapshot_declaration#declare }"
      done < <(declare -p)
      declare -f
    } > "$check/environment.sh"
  '';

  argsFor = {
    # Reading doInstallCheck here recurses for finalAttrs Python packages, so
    # the wheel layer supplies the native package's value.
    wantsInstallCheck ? false,
  }: old: let
    # Python suites run in installCheckPhase because they test the installed
    # package; C suites run in checkPhase. make-derivation.nix gates both off
    # on cross.
    wantsCheck = old.doCheck or false;
  in
    if !wantsCheck && !wantsInstallCheck
    then {}
    else {
      # Keep the assertion lazy because finalAttrs packages can derive outputs
      # from their final derivation.
      outputs = assert lib.assertMsg (!(lib.elem "check" (old.outputs or ["out"])))
      "check-output wrapper applied to a derivation that already has a 'check' output";
        (old.outputs or ["out"]) ++ ["check"];

      # Cross stdenv drops check inputs. C suites need them to compile tests;
      # Python install checks receive theirs only in the run derivation.
      nativeBuildInputs =
        (old.nativeBuildInputs or [])
        ++ usable (lib.optionals wantsCheck (old.nativeCheckInputs or []));
      buildInputs =
        (old.buildInputs or [])
        ++ usable (lib.optionals wantsCheck (old.checkInputs or []));

      # Keep hook functions defined while preventing their phases from running
      # during the cross build.
      dontUsePytestCheck = wantsInstallCheck;
      dontUseUnittestCheck = wantsInstallCheck;
      # A Python source tree's Makefile is not evidence of a C-style check
      # target, so preserve the phase declaration.
      wasixCheckIsCSuite = wantsCheck;

      # checkPhase suites snapshot where checkPhase would have run;
      # installCheck suites snapshot after install and fixup, which is what
      # preDistPhases gives with installCheckPhase gated off.
      preInstallPhases = (old.preInstallPhases or []) ++ lib.optional wantsCheck "wasixCheckSnapshotPhase";
      preDistPhases = (old.preDistPhases or []) ++ lib.optional (wantsInstallCheck && !wantsCheck) "wasixCheckSnapshotPhase";

      # Nix scans store-path hashes in the output's NAR. Preserve every hash
      # visible before compression so its final scan can intersect them with
      # the derivation's authoritative reference candidates.

      # Resolve wasixCheckPrebuild in the build shell because package tweaks
      # compose after this wrapper.
      wasixCheckSnapshotPhase = assert lib.assertMsg (referenceScanner != null && snapshotZstd != null)
      "check-output requires a native reference scanner and zstd"; ''
        if [ -z "''${check:-}" ]; then
          echo "no check output on this derivation; skipping the test snapshot"
        else
          mkdir -p "$check"
          if (
            if [ -n "''${wasixCheckPrebuild:-}" ]; then
              eval "$wasixCheckPrebuild"
            elif [ -z "''${wasixCheckIsCSuite:-}" ]; then
              :
            elif [ -f CMakeCache.txt ]; then
              :
            elif [ -f Makefile ] || [ -f makefile ] || [ -f GNUmakefile ]; then
              make -j"''${NIX_BUILD_CORES:-1}" "''${checkTarget:-check}" TESTS=
            fi
          ) > "$check/prebuild.log" 2>&1; then
            _prebuild_rc=0
          else
            _prebuild_rc=$?
          fi
          cat "$check/prebuild.log"
          if [ "$_prebuild_rc" -ne 0 ]; then
            if grep -q "No rule to make target" "$check/prebuild.log"; then
              echo "no check/test target configured on this derivation; skipping the test snapshot" >&2
            else
              echo "check prebuild failed with status $_prebuild_rc; failing the build" >&2
              exit "$_prebuild_rc"
            fi
          fi
          ${snapshotEnvironment}
          case "$PWD" in
            "$NIX_BUILD_TOP") _build_rel="." ;;
            "$NIX_BUILD_TOP"/*) _build_rel="''${PWD#"$NIX_BUILD_TOP"/}" ;;
            *)
              echo "check snapshot directory is outside NIX_BUILD_TOP: $PWD" >&2
              exit 1
              ;;
          esac
          printf '%s\n' "$_build_rel" > "$check/.builddir"
          tar -C "$NIX_BUILD_TOP" -cf "$check/tree.tar" "''${_build_rel%%/*}"
          ${lib.getExe' referenceScanner "check-reference-scanner"} "$check" "$check/reference-hashes"
          ${lib.getExe' snapshotZstd "zstd"} -q -T1 -3 --rm "$check/tree.tar"
        fi
      '';
    };
in {
  inherit usable;

  # For set/stdenv.nix: applied to every derivation, so checkPhase suites only.
  checkOutputArgs = argsFor {};
  # For the wheel layer; `wants` comes from the native nixpkgs package.
  installCheckOutputArgsIf = wants: argsFor {wantsInstallCheck = wants;};
}
