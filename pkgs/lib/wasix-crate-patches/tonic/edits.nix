# tonic: the uds transport names `tokio::net::UnixStream`, which wasix lacks, so
# the floor stubs it the way upstream stubs windows. The 0.13 floor is the same
# edit against that line's tree; 0.9 through 0.12 keep their uds behind
# cfg(unix), which already excludes wasi, and 0.6 has no uds transport at all,
# so all are stock.
_: {
  edited = ["=0.13.1" ">=0.14.2"];
  stock = ["=0.6.2" "=0.9.2" "=0.11.0" "=0.12.3"];
}
