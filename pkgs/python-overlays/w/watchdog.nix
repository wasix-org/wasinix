# No suite: wasix has no inotify, so watchdog runs its polling fallback and
# the suite's event-delivery assertions against native observers fail.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.checks.captured.install = false;
  # PyPI ships only native and sdist wheels (no py3-none-any); wasix builds the
  # pure polling fallback, so the registry must serve ours.
  passthru.wasinix.publication.supersedesPyPI = true;
}
