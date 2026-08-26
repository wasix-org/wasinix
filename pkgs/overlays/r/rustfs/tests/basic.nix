# Runtime behavior checks for the RustFS WebC under Wasmer. `--version`/`--help` are
# handled by clap in Opt::parse_command and exit 0 before the server binds, so
# they exercise the whole startup path that matters for "does it run": the wasm
# module loads, std/env init and the tokio runtime come up, and argv parsing
# works — without needing storage volumes or a bound port.
{
  commands,
  entry,
  harnesses,
  ...
}: let
  wasix = builtins.attrValues entry.commands;
in {
  version = harnesses.wasixShell {
    name = "rustfs-version";
    shell = commands.bash;
    commands = wasix;
    runtime.threads = true;
    script = "rustfs --version";
  };

  help = harnesses.wasixShell {
    name = "rustfs-help";
    shell = commands.bash;
    commands = wasix;
    runtime.threads = true;
    script = "rustfs --help";
  };
}
