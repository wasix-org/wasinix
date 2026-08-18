# Dependencies our edits pull into a crate that upstream lacks, declared once so
# the pin lives in one place. A crate's edits.nix references these by name in its
# `adds`; crate-edits.nix writes them into consumers' locks and vendors.
{
  libc = {
    name = "libc";
    version = "0.2.186";
    checksum = "68ab91017fe16c622486840e4c83c9a37afeff978bd239b5293d61ece587de66";
    deps = [];
  };
  # mio's 0.8 backend predates wasix 0.13's AddrIp6 split, so that line pins 0.12.
  wasix12 = {
    name = "wasix";
    version = "0.12.21";
    checksum = "c1fbb4ef9bbca0c1170e0b00dd28abc9e3b68669821600cad1caaed606583c6d";
    deps = ["wasi"];
  };
  wasix = {
    name = "wasix";
    version = "0.13.2";
    checksum = "ae86f02046da16a333a9129d31451423e1657737ecdafed4193838a5f54c5cfe";
    deps = ["wasi"];
  };
}
