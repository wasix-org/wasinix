# glog for wasix, needed by opencv_contrib's sfm module.
{exposeExtendedPackage}:
exposeExtendedPackage {
  # "Platform not supported by glog": its platform.h whitelist has no wasi entry.
  # Emscripten is the closest match, also lacking SYS_write and /bin/mail.
  postPatch = ''
    substituteInPlace src/glog/platform.h \
      --replace-fail '#elif defined(__EMSCRIPTEN__)' '#elif defined(__EMSCRIPTEN__) || defined(__wasi__)'
  '';
}
