# openai for wasix. Drop sounddevice from the (nixpkgs-promoted) hard deps: it
# is only for openai[voice-helpers], needs portaudio (a native audio library,
# absent and meaningless under wasm), and does not even evaluate for wasm (its
# patch reads hostPlatform.extensions.sharedLibrary). overridePythonAttrs, not
# overrideAttrs: buildPythonPackage must recompute propagatedBuildInputs AND
# requiredPythonModules (makePythonPath forces the latter) without it. The
# client and its JSON/HTTP core (jiter, httpx, pydantic) are unaffected.
{
  exposePackage,
  package,
}:
exposePackage (
  package.overridePythonAttrs (old: {
    doCheck = false;
    passthru =
      (old.passthru or {})
      // {
        wasinix = ((old.passthru or {}).wasinix or {}) // {checks.captured.install = false;};
      };
    dependencies =
      builtins.filter (d: (d.pname or d.name or "") != "sounddevice") (old.dependencies or []);
  })
)
