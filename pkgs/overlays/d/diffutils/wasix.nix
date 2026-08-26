{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  passthru = {
    wasix.supportedProfiles = ["off"];
    wasinix.shipped = true;
    wasmer = {
      name = "diff";
      entrypoint = "diff";
      commands = map (name: {inherit name;}) [
        "cmp"
        "diff"
        "diff3"
        "sdiff"
      ];
    };
  };
  patches = [./patches/guard-so-debug-test.patch];
  postInstall = ''
    for program in cmp diff diff3 sdiff; do
      mv "$out/bin/$program" "$out/bin/$program.wasm"
    done
  '';
}
