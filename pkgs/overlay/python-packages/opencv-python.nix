{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # This metapackage inherits pytest but ships no tests. The opencv4 package's
  # cv2 operations check supplies runtime coverage.
  passthru.wasix.installCheck = false;
}
pyprev.opencv-python
