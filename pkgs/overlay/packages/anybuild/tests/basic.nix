{
  testLib,
  wasmerPkgs,
  ...
}: {
  version = testLib.mkWasixRun {
    name = "anybuild-version";
    wasixPkgs = [wasmerPkgs.anybuild];
    script = "anybuild --version";
  };

  local-build = testLib.mkWasixRun {
    name = "anybuild-local-build";
    wasixPkgs = [wasmerPkgs.anybuild];
    script = ''
      mkdir project
      printf 'hello\n' > project/index.html
      cat > project/Anybuild <<'EOF'
      load("//anybuild/tools:staticfile.bzl", "staticfile_build", "staticfile_config", "staticfile_serve")

      config = staticfile_config(schema = 1, sws_version = "2.38.0")
      build = staticfile_build(config)
      staticfile_serve(
          config,
          build,
          name = "smoke",
          build_post = [run("bash -c 'printf built > bash-ran'")],
      )
      EOF

      anybuild build project --skip-prepare
      test "$(cat project/.anybuild/local/build/opt/static_app/bash-ran)" = built
    '';
  };
}
