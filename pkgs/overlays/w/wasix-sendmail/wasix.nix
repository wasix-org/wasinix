{
  exposeWasixPackage,
  package,
}:
exposeWasixPackage (
  package.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        wasinix.shipped = true;
        wasmer = {
          owner = "sendmail";
          name = "sendmail";
        };
      };
  })
)
