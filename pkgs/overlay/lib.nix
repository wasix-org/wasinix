# Helpers for wasix package overlay entries. Because the profile's stdenv
# (replaceCrossStdenv) already builds with wasixcc and auto-threads linked deps,
# these only apply per-package tweaks — no stdenv override, no dep threading.
{lib}: rec {
  # Merge non-empty script fragments.
  mergeScript = frags: lib.concatStringsSep "\n" (lib.filter (f: f != "" && f != null) frags);

  # Standard library tweaks: doCheck=false + the usual hooks. No stdenv override or
  # dep threading — the profile's stdenv already builds with wasixcc.
  libTweaks = {
    configureFlags ? [],
    makeFlags ? [],
    env ? {},
    extraBuildInputs ? [],
    extraNativeBuildInputs ? [],
    extraPropagatedBuildInputs ? [],
    doCheck ? false,
    postPatch ? "",
    preConfigure ? "",
    postInstall ? "",
    overrideAttrs ? (_old: {}),
  }: pkg:
    pkg.overrideAttrs (
      old:
        {
          inherit doCheck;
          configureFlags = (old.configureFlags or []) ++ configureFlags;
          makeFlags = (old.makeFlags or []) ++ makeFlags;
          buildInputs = (old.buildInputs or []) ++ extraBuildInputs;
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ extraNativeBuildInputs;
          propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ extraPropagatedBuildInputs;
          env = (old.env or {}) // env;
          postPatch = mergeScript [(old.postPatch or "") postPatch];
          preConfigure = mergeScript [(old.preConfigure or "") preConfigure];
          postInstall = mergeScript [(old.postInstall or "") postInstall];
        }
        // overrideAttrs old
    );

  # Rename bin/<wasmName> -> <wasmName>.wasm (the convention allWasm collects),
  # optionally asyncifying. For leaf CLIs.
  wasmRename = {
    wasmName,
    asyncifyFlags ? null,
    binaryen ? null, # only needed when asyncifyFlags != null
  }: pkg:
    pkg.overrideAttrs (old: {
      # mergeScript (not `+`): Nix strips the leading newline of an indented
      # string, so `old + ''<nl>if…''` would glue onto a non-empty old.postInstall
      # with no separator.
      # Rename in whichever output holds bin/ — usually $out, but multi-output
      # packages put it in $bin (e.g. curl's default output is "bin").
      postInstall = mergeScript [
        (old.postInstall or "")
        ''
          for _bindir in "$out" ''${bin:+"$bin"}; do
            if [ -f "$_bindir/bin/${wasmName}" ]; then
              mv "$_bindir/bin/${wasmName}" "$_bindir/bin/${wasmName}.wasm"
              ${lib.optionalString (asyncifyFlags != null) ''
              ${binaryen}/bin/wasm-opt --asyncify ${asyncifyFlags} -O2 "$_bindir/bin/${wasmName}.wasm" -o "$_bindir/bin/${wasmName}.wasm"''}
            fi
          done
        ''
      ];
    });
}
