# mysql: upstream ties the unix-socket transport and the AsRawFd impls to `unix`,
# so wasix loses raw-fd access and the non-unix connect_socket stub keeps the
# wrong signature. The floor patch routes wasix down the TCP path and restores
# AsRawFd; it fits 26.0.1 through 28.0.0 (a version it no longer fits hard-fails).
_: {
  edited = [">=26.0.1"];
}
