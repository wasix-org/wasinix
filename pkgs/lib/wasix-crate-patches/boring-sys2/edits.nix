# boring-sys2: drives BoringSSL's cmake build through wasixcc via an added
# toolchain file, and locates the sysroot with `wasixccenv print-sysroot`. Built
# only by the fork's own cmake path, so it is unverified here. boring2 and
# tokio-boring2 need no edit and pass through.
{...}: {
  edited = ["=4.15.13"];
}
