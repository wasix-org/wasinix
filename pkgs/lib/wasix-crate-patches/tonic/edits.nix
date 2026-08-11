# tonic: the uds transport names `tokio::net::UnixStream`, which wasix lacks, so
# the floor stubs it the way upstream stubs windows. The 0.13 floor is the same
# edit against that line's tree; 0.12 keeps its uds behind cfg(unix), which
# already excludes wasi, so it is stock.
{...}: {
  edited = ["=0.13.1" ">=0.14.2"];
  stock = ["=0.12.3"];
}
