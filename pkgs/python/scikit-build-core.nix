# scikit-build-core is pyarrow-24.0.0's build backend. Its nativeCheckInputs (cattrs, virtualenv,
# pytest-subprocess -> anyio -> trustme -> cryptography -> bcrypt) drag native rust wheels into
# every consumer's build closure. The native bcrypt then fails: the setuptools-rust hook is a
# single derivation shared with the wasix rust wheels (see setuptools-rust.nix), so it forces the
# wasm target onto the native build and rustc errors "could not find specification for target".
# We don't run this build tool's own test suite; disable it so its check-only rust deps leave the
# closure. Ungated: harmless on both the cross set and the native pythonForBuild.
{pyprev, ...}:
pyprev.scikit-build-core.overridePythonAttrs (_: {doCheck = false;})
