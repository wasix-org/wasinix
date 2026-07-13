# huggingface-hub for wasix. Two deps only its `hf`/huggingface-cli CLI needs
# are dropped; the library imports both lazily, so `import huggingface_hub`
# still works, and smolagents then needs no Rust wheel:
#   - hf-xet: a Rust download accelerator (the hub falls back to plain HTTP,
#     is_xet_available() guards its import). Avoids porting the crate
#     (getrandom 0.2/0.3/0.4 + openssl).
#   - typer: its shellingham dep patches in a `ps` path via procps, which
#     infinite-recurses for the wasi platform. The library doesn't use typer.
# overridePythonAttrs, not a propagatedBuildInputs filter: buildPythonPackage
# must recompute requiredPythonModules too (makePythonPath forces it), else the
# dropped deps reappear and re-trigger the eval failures.
{pyprev, ...}:
pyprev.huggingface-hub.overridePythonAttrs (old: {
  doCheck = false;
  # We dropped hf-xet/typer, but they stay in the wheel's Requires-Dist, so the
  # runtime-deps check (which flags absent declared deps) would fail.
  dontCheckRuntimeDeps = true;
  dependencies =
    builtins.filter
    (d: !builtins.elem (d.pname or d.name or "") ["hf-xet" "typer"])
    (old.dependencies or []);
})
