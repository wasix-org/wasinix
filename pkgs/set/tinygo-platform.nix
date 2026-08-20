{
  lib,
  buildGoModule,
  tinygo,
}:
lib.extendMkDerivation {
  constructDrv = buildGoModule;
  extendDrvArgs = finalAttrs: packageAttrs: let
    mainProgram = finalAttrs.meta.mainProgram or finalAttrs.pname;
  in {
    nativeBuildInputs = (packageAttrs.nativeBuildInputs or []) ++ [tinygo];

    buildPhase = ''
      runHook preBuild

      declare -a packagePatterns tinygoFlags tinygoLdflags tinygoPackages tinygoTags
      concatTo tinygoFlags tinygoBuildFlags
      concatTo tinygoPackages subPackages
      if (( ''${#tinygoPackages[@]} == 0 )); then
        packagePatterns=(./...)
      else
        for package in "''${tinygoPackages[@]}"; do
          packagePatterns+=("./$package")
        done
      fi

      mapfile -t mainPackages < <(
        go list -mod=vendor -f '{{if eq .Name "main"}}{{.ImportPath}}{{end}}' "''${packagePatterns[@]}" |
          sed '/^$/d'
      )
      (( ''${#mainPackages[@]} > 0 )) || { echo "no main Go packages found"; exit 1; }

      concatTo tinygoTags tags
      if (( ''${#tinygoTags[@]} > 0 )); then
        joinedTags=$(IFS=,; echo "''${tinygoTags[*]}")
        tinygoFlags+=("-tags=$joinedTags")
      fi

      concatTo tinygoLdflags ldflags
      declare -a supportedLdflags
      for flag in "''${tinygoLdflags[@]}"; do
        case "$flag" in
          -buildid=|-s|-w) ;;
          *) supportedLdflags+=("$flag") ;;
        esac
      done
      if (( ''${#supportedLdflags[@]} > 0 )); then
        tinygoFlags+=("-ldflags=''${supportedLdflags[*]}")
      fi

      export HOME="$TMPDIR/home"
      mkdir -p "$HOME" "$GOPATH/bin"
      for package in "''${mainPackages[@]}"; do
        if (( ''${#mainPackages[@]} == 1 )); then
          name=${lib.escapeShellArg mainProgram}
        else
          name="''${package##*/}"
        fi
        ${lib.getExe tinygo} build -target=wasip1 -no-debug \
          "''${tinygoFlags[@]}" -o "$GOPATH/bin/$name" "$package"
      done

      runHook postBuild
    '';
  };
}
