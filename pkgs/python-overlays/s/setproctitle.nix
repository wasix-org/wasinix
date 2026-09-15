{exposeExtendedPackage}:
exposeExtendedPackage {
  # The suite inspects and forks host processes; WASIX exposes neither view.
  passthru.wasinix.checks.captured.install = false;
  # PyPI ships only native wheels (no py3-none-any); WASIX builds the pure no-op
  # fallback instead, so the registry must serve ours or the module is
  # uninstallable on WASIX.
  passthru.wasinix.publication.supersedesPyPI = true;
}
