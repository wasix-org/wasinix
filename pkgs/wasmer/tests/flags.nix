{
  harnesses,
  pkgs,
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
  flagCommand = {
    name = "wasinix-harness-flag-probe";
    entrypoint = "wasinix-harness-flag-probe";
    artifact.shim = flagProbe;
  };
  invocationArgs = harnesses.invocationWasmerArgsEnv;
in
  harnesses.hostShell {
    name = "host-shell-invocation-flags";
    wasixCommands = [flagCommand];
    wasmerArgs = ["--static-flag"];
    script = ''
      ${invocationArgs}=--first-flag wasinix-harness-flag-probe --first-flag --second-flag
      ${invocationArgs}=--second-flag wasinix-harness-flag-probe --second-flag --first-flag
    '';
  }
