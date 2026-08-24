# The wasix ABI profile table (EH/PIC variants). Everything derives from it:
#   - project/wasinix.nix merges the fields into each crossSystem, so they appear as
#     hostPlatform.wasmExceptions/wasmPic (read by set/stdenv.nix and profileOf).
#   - toolchain/sysroot/ builds one sysroot per profile from sysrootEncodings.
#   - pkgs/lib exposes profile-set constructors and the platform -> profile lookup.
#
# wasmExceptions: "legacy" | "yes" (exnref) | "no", the values wasixcc's
# WASIXCC_WASM_EXCEPTIONS expects. wasmPic toggles -fPIC + the PIC sysroot
# variant. PIC is only valid with EH (see build32-general.sh), so there is no
# off+pic profile. `off` exists for asyncify consumers (bash: fork/setjmp).
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

  # Default profile for shipped binaries and the library matrix. A package that
  # needs a different profile declares it via passthru.wasix; the project
  # constructor reads that to build packages.preferred.
  defaultProfileName = "exnrefEh";

  # The {eh, pic, exnref} encoding of each profile, which wasix-libc's
  # build32-general.sh (and thus toolchain/sysroot/) selects variants by.
  sysrootEncodings =
    builtins.mapAttrs (_: p: {
      eh = p.wasmExceptions != "no";
      exnref = p.wasmExceptions == "yes";
      pic = p.wasmPic or false;
    })
    profiles;

  # Subdir per profile under the combined sysroot (off -> sysroot, eh ->
  # sysroot-eh, ...). The naming is fixed by wasixcc, which picks the subdir
  # under WASIXCC_SYSROOT_PREFIX by EH/PIC; it matches the release tarballs.
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

  # Profile name for a host platform: match its wasmExceptions/wasmPic fields
  # back against the table (the reverse of the crossSystem merge).
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
