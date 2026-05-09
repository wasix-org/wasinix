{
  makeWasmerPackage,
  gettext,
}:
makeWasmerPackage {
  package = gettext;
  name = "gettext";
  inherit (gettext) version;
  description = "GNU gettext internationalization and localization tools";
}
