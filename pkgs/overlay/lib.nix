# Helpers for wasix package overlay entries. Because the profile's stdenv
# (replaceCrossStdenv) already builds with wasixcc and auto-threads linked deps,
# these only apply per-package tweaks — no stdenv override, no dep threading.
{lib}: rec {
  # Merge non-empty script fragments.
  mergeScript = frags: lib.concatStringsSep "\n" (lib.filter (f: f != "" && f != null) frags);

  # The profile/ABI-variant name (off / eh / ehpic / exnrefEh / exnrefEhpic) derived from a host
  # platform's wasmExceptions/wasmPic fields — the single source of truth for the EH/PIC -> variant
  # mapping (consumed by both the rust gate in default.nix and python's profile gate).
  variantOf = hp: let
    exc = hp.wasmExceptions or "no";
    pic = hp.wasmPic or false;
  in
    if exc == "no"
    then "off"
    else if exc == "yes"
    then
      (
        if pic
        then "exnrefEhpic"
        else "exnrefEh"
      )
    else if pic
    then "ehpic"
    else "eh";

  # The standard nixpkgs phases + their pre/post hooks: string attrs that must be CONCATENATED
  # (not replaced) when merged onto a derivation. Used by extendDrv.
  scriptPhases = [
    "preUnpack"
    "unpackPhase"
    "postUnpack"
    "prePatch"
    "patchPhase"
    "postPatch"
    "preConfigure"
    "configurePhase"
    "postConfigure"
    "preBuild"
    "buildPhase"
    "postBuild"
    "preCheck"
    "checkPhase"
    "postCheck"
    "preInstall"
    "installPhase"
    "postInstall"
    "preFixup"
    "fixupPhase"
    "postFixup"
    "preInstallCheck"
    "installCheckPhase"
    "postInstallCheck"
    "preDist"
    "distPhase"
    "postDist"
  ];

  # Merge a tweak attrset onto a derivation's `old` attrs, dispatching per-attr by KIND so callers
  # never hand-write `(old.X or []) ++ …` / `(old.X or "") + …` boilerplate:
  #   - a function           -> applied to the old value (the escape for filter/replace/old-dependent)
  #   - a known script phase -> concatenated (mergeScript)
  #   - a list               -> appended to the old list
  #   - an attrset (env/meta/passthru) -> deep-merged recursively, so nested lists append too
  #   - anything else (scalar / derivation / path) -> set
  # Returns the attrs to hand to overrideAttrs.
  extendDrv = old: new:
    lib.mapAttrs (
      name: val: let
        cur = old.${name} or null;
      in
        if builtins.isFunction val
        then val cur
        else if builtins.elem name scriptPhases
        then mergeScript [cur val]
        else if builtins.isList val
        then (if cur == null then [] else cur) ++ val
        else if lib.isAttrs val && !lib.isDerivation val && lib.isAttrs cur && !lib.isDerivation cur
        then cur // extendDrv cur val
        else val
    )
    new;

  # Per-package wasix tweaks. Pass any derivation attrs; each is merged onto the package by kind
  # (see extendDrv) — phases concat, lists append, attrsets deep-merge, scalars set, and a function
  # value receives the old value (for filters / replacements). doCheck defaults to false (cross
  # can't run target tests; pass doCheck = true to override). No escape-hatch, no per-attr params.
  libTweaks = tweaks: pkg:
    pkg.overrideAttrs (old: extendDrv old ({doCheck = false;} // tweaks));

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
