{
  commands,
  harnesses,
  entry,
  ...
}: {
  version = harnesses.wasixShell {
    name = "anybuild-version";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands;
    script = "anybuild --version";
  };

  local-build = harnesses.wasixShell {
    name = "anybuild-local-build";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
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
          name = "behavior",
          build_post = [run("bash -c 'printf built > bash-ran'")],
      )
      EOF

      anybuild build project --skip-prepare
      test "$(cat project/.anybuild/local/build/opt/static_app/bash-ran)" = built
    '';
  };
}
