{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  configureFlags = [
    "--with-data-packaging=archive"
    "--disable-extras"
    "--disable-samples"
    "--disable-tests"
    "--disable-tools"
  ];
  postPatch = ''
    patch -p1 < ${./patches/no-tzname-on-unknown.patch}
  '';
  preConfigure = ''
    cp config/mh-linux config/mh-unknown
  '';
}
prev.icu
