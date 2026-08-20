# gawk, for the awk git's shell subcommands call. Off-EH profile only, like the
# coreutils it sits beside: gawk forks (system(), | getline), which needs the
# asyncify pass that binaryen cannot apply to Wasm-EH modules.
{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {
  wasmName = "gawk";
  posixAlias = true;
} (
  helpers.libTweaks {
    passthru.wasinix.shipped = true;
    passthru.wasix.supportedProfiles = ["off"];
    # The bundled extensions are dlopen'd, which a static wasm build cannot do,
    # and filefuncs wants major()/minor() from a header WASIX lacks.
    configureFlags = ["--disable-extensions"];
    # gawk compiles its own gnulib regex, whose regcomp/regfree wasix-libc also
    # defines; wasm-ld rejects the duplicates GNU ld would first-wins. gawk's
    # objects come before libc, so it keeps using the regex it was built against.
    env.NIX_LDFLAGS = "--allow-multiple-definition";
    # Git's shell subcommands run awk by its store path, so that name has to survive
    # the *.wasm rename; the versioned copy is dead weight.
    passthru.wasmer.entrypoint = "gawk";
    passthru.wasmer.commands = [
      {name = "gawk";}
      {
        name = "awk";
        module = "gawk";
        wasm = "gawk.wasm";
        output = "gawk.wasm";
      }
    ];
    postInstall = ''
      rm -f "$out/bin/gawk-"*
      ln -sf gawk.wasm "$out/bin/awk"
    '';
  }
  prev.gawk
)
