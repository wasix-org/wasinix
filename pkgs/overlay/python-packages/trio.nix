{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.trio {
  # Gate optional platform APIs by the capabilities WASIX exposes.
  postPatch = ''
    substituteInPlace src/trio/_core/__init__.py \
      --replace-fail 'sys.platform != "linux" and sys.platform != "win32" and sys.platform != "android"' 'hasattr(__import__("select"), "kqueue") and not hasattr(__import__("select"), "epoll")'
    substituteInPlace src/trio/lowlevel.py \
      --replace-fail 'sys.platform != "linux" and (_t.TYPE_CHECKING or not hasattr(_select, "epoll"))' '_t.TYPE_CHECKING or (hasattr(_select, "kqueue") and not hasattr(_select, "epoll"))'
    substituteInPlace src/trio/_socket.py \
      --replace-fail 'sys.platform != "win32" or (' 'TYPE_CHECKING or ('
    substituteInPlace src/trio/socket.py \
      --replace-fail 'if sys.implementation.name == "cpython":' 'if sys.implementation.name == "cpython" and all(hasattr(_stdlib_socket, name) for name in ("if_indextoname", "if_nametoindex")):'
    substituteInPlace src/trio/_core/_wakeup_socketpair.py \
      --replace-fail \
      $'        self.wakeup_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1)\n        self.write_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1)' \
      $'        with contextlib.suppress(OSError):\n            self.wakeup_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1)\n            self.write_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1)'
    substituteInPlace src/trio/_subprocess_platform/waitid.py \
      --replace-fail '    waitid_cffi = waitid_ffi.dlopen(None).waitid  # type: ignore[attr-defined]' \
      $'    try:\n        waitid_cffi = waitid_ffi.dlopen(None).waitid  # type: ignore[attr-defined]\n    except AttributeError as ex:\n        raise ImportError from ex'
  '';
}
