{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.opencv-python {
  # This metapackage inherits pytest but ships no tests. The opencv4 package's
  # cv2 operations check supplies runtime coverage.
  passthru.wasinix.checks.captured.install = false;
}
