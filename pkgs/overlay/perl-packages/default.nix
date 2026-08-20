{
  final,
  helpers,
  wasixRunStub,
}: _final: prev: let
  buildPerl = final.buildPackages.perl;
  checkPerl = final.buildPackages.writeShellScriptBin "perl" ''
    args=()
    # Test::Harness forwards its own library paths to HARNESS_PERL.
    IFS=: read -r -a perl5lib <<< "''${PERL5LIB-}"
    cleanPerl5lib=()
    for path in "''${perl5lib[@]}"; do
      case "$path" in
        ${buildPerl}/*) ;;
        *) cleanPerl5lib+=("$path") ;;
      esac
    done
    export PERL5LIB="$(IFS=:; echo "''${cleanPerl5lib[*]}")"
    for arg in "$@"; do
      case "$arg" in
        -I${buildPerl}/*) ;;
        *) args+=("$arg") ;;
      esac
    done
    exec ${wasixRunStub}/bin/wasix-run ${final.perl}/bin/perl "''${args[@]}"
  '';
in {
  buildPerlPackage = args:
    (prev.buildPerlPackage args).overrideAttrs (old: {
      # The harness needs fork to capture TAP; HARNESS_PERL keeps the tests on WASIX.
      wasixCheckPrebuild = ":";
      preCheck = helpers.mergeScript [
        (old.preCheck or "")
        ''
          export PATH=${buildPerl}/bin:$PATH
          export HARNESS_PERL=${checkPerl}/bin/perl
          checkFlagsArray+=(
            "PERL=${buildPerl}/bin/perl"
            "FULLPERL=${buildPerl}/bin/perl"
            "PERLRUN=${buildPerl}/bin/perl"
            "FULLPERLRUN=${buildPerl}/bin/perl"
            "ABSPERLRUN=${buildPerl}/bin/perl"
            "FULLPERLRUNINST=${buildPerl}/bin/perl"
          )
        ''
      ];
    });
}
