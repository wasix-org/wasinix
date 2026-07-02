# The canonical table of wasix ABI profiles — the single source of truth for the
# EH/PIC variant matrix. Everything else derives from it:
#   - set/mk-pkgs.nix merges a profile's platform fields into the crossSystem, so
#     they ride on the platform record as `hostPlatform.wasmExceptions` /
#     `hostPlatform.wasmPic` (readable by set/stdenv.nix and profileOf).
#   - toolchain/sysroot/ builds one sysroot per profile from `sysrootEncodings`
#     (the {eh, pic, exnref} booleans wasix-libc's build32-general.sh speaks).
#   - pkgs/lib (the wasix helpers) exposes profile-set constructors and the
#     platform -> profile-name lookup for the passthru.wasix support contract.
#
# wasmExceptions: "legacy" | "yes" (exnref) | "no" (off, asyncify) — values are
# what wasixcc's WASIXCC_WASM_EXCEPTIONS expects. wasmPic toggles -fPIC + the PIC
# sysroot variant. PIC is only valid with EH (see build32-general.sh), so there is
# no off+pic profile. `off` exists for asyncify consumers (bash: fork/setjmp).
rec {
  profiles = {
    eh = {wasmExceptions = "legacy";};
    ehpic = {
      wasmExceptions = "legacy";
      wasmPic = true;
    };
    exnrefEh = {wasmExceptions = "yes";};
    exnrefEhpic = {
      wasmExceptions = "yes";
      wasmPic = true;
    };
    # No Wasm-EH: setjmp/longjmp and fork() both go through asyncify (bash).
    off = {wasmExceptions = "no";};
  };

  profileNames = builtins.attrNames profiles;

  # The profile shipped binaries are built in by default, and the profile the
  # per-profile library matrix is anchored on. A package that needs a different
  # profile declares it via passthru.wasix (supportedProfiles/preferredProfile —
  # see pkgs/lib); pkgs/default.nix reads that to build preferredPackages.
  defaultProfileName = "exnrefEh";

  # The {eh, pic, exnref} encoding of each profile — what wasix-libc's
  # build32-general.sh (and thus toolchain/sysroot/) selects variants by.
  sysrootEncodings =
    builtins.mapAttrs (_: p: {
      eh = p.wasmExceptions != "no";
      exnref = p.wasmExceptions == "yes";
      pic = p.wasmPic or false;
    })
    profiles;

  # Subdir name under the combined sysroot, matching the release tarballs
  # (off -> sysroot, eh -> sysroot-eh, exnrefEhpic -> sysroot-exnref-ehpic, …).
  # wasixcc points WASIXCC_SYSROOT_PREFIX at the combined sysroot and picks the
  # subdir by EH/PIC, so this naming is fixed by wasixcc's convention.
  sysrootSubdirs =
    builtins.mapAttrs (
      _: enc:
        if !enc.eh
        then "sysroot"
        else
          "sysroot-"
          + (
            if enc.exnref
            then "exnref-"
            else ""
          )
          + "eh"
          + (
            if enc.pic
            then "pic"
            else ""
          )
    )
    sysrootEncodings;

  # The profile name for a host platform (the reverse of the crossSystem merge):
  # match the platform's wasmExceptions/wasmPic fields back against the table.
  profileOf = hp: let
    matches =
      builtins.filter (
        name: let
          p = profiles.${name};
        in
          (hp.wasmExceptions or "no")
          == p.wasmExceptions
          && (hp.wasmPic or false) == (p.wasmPic or false)
      )
      profileNames;
  in
    if matches == []
    then throw "profileOf: platform (wasmExceptions=${hp.wasmExceptions or "no"}, wasmPic=${builtins.toJSON (hp.wasmPic or false)}) matches no wasix profile"
    else builtins.head matches;
}
