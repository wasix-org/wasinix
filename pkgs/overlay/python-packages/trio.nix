{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # Select the kqueue exports by capability rather than by non-Linux platform.
  postPatch = ''
    substituteInPlace src/trio/_core/__init__.py \
      --replace-fail 'sys.platform != "linux" and sys.platform != "win32" and sys.platform != "android"' 'hasattr(__import__("select"), "kqueue")'
    substituteInPlace src/trio/lowlevel.py \
      --replace-fail 'sys.platform != "linux" and (_t.TYPE_CHECKING or not hasattr(_select, "epoll"))' '_t.TYPE_CHECKING or hasattr(_select, "kqueue")'
  '';
}
pyprev.trio
