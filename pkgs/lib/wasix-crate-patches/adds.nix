# Dependencies our edits pull into a crate that upstream lacks, declared once so
# the pin lives in one place. A crate's edits.nix references these by name in its
# `adds`; crate-edits.nix writes them into consumers' locks and vendors.
{
  wasix = {
    name = "wasix";
    version = "0.13.2";
    checksum = "ae86f02046da16a333a9129d31451423e1657737ecdafed4193838a5f54c5cfe";
    deps = ["wasi"];
  };
}
