# nixpkgs unbounds the build-time mypy requirement by matching the current
# release's literal range; an older release bounds a different one (3.4.7 caps
# at 1.20, not 2.2). Rewrite the whole MYPYC_SPEC line instead, which states the
# intent rather than one version's text, and drop the release's setuptools cap
# for the same reason: it predates the setuptools we build with.
{
  pyprev,
  helpers,
  lib,
  ...
}:
helpers.libTweaks (lib.optionalAttrs ((pyprev.charset-normalizer.passthru.wasix.historySpec or null) != null) {
  postPatch = _: ''
    sed -i 's/^MYPYC_SPEC = .*/MYPYC_SPEC = "mypy"/' _mypyc_hook/backend.py
    sed -i 's/^requires = \["setuptools[^]]*\]/requires = ["setuptools"]/' pyproject.toml
  '';
})
pyprev.charset-normalizer
