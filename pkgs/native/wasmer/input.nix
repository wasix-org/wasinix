{
  revision,
  wasmer,
}:
wasmer.overrideAttrs (old: {
  passthru =
    (old.passthru or {})
    // {
      wasinix =
        ((old.passthru or {}).wasinix or {})
        // {
          update = {
            noteVersion = "${old.version}-${revision}";
            notes = [
              {message = "recheck and drop any Wasmer patches that landed upstream; see WASIX-TODO.md";}
            ];
          };
        };
    };
})
