# tonic: the uds transport names `tokio::net::UnixStream`, which wasix lacks, so
# the floor stubs it the way upstream stubs windows. Releases below 0.14.2 are
# unvetted; above it the floor carries forward.
{...}: {
  edited = [">=0.14.2"];
}
