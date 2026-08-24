# curl-sys: WASIX sockets use the POSIX curl ABI but the target does not set
# cfg(unix).
_: {
  edited = [">=0.4.87"];
  stock = ["<0.4.87"];
}
