{
  pkgs,
  testLib,
}: let
  flagProbe = pkgs.writeShellScriptBin "wasinix-harness-flag-probe" ''
    case " $WASMER_FLAGS " in
      *" --volume "*" --cwd "*" --static-flag "*) ;;
      *) exit 1 ;;
    esac
    case " $WASMER_FLAGS " in
      *" $1 "*) ;;
      *) exit 1 ;;
    esac
    case " $WASMER_FLAGS " in
      *" $2 "*) exit 1 ;;
      *) ;;
    esac
  '';
  invocationArgs = testLib.invocationWasmerArgsEnv;
in
  testLib.mkWasixRun {
    name = "host-shell-invocation-flags";
    wasixPkgs = [flagProbe];
    wasmerArgs = ["--static-flag"];
    script = ''
      ${invocationArgs}=--first-flag wasinix-harness-flag-probe --first-flag --second-flag
      ${invocationArgs}=--second-flag wasinix-harness-flag-probe --second-flag --first-flag
    '';
  }
