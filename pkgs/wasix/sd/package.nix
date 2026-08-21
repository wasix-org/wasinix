# sd: a sed-like find-replace tool in Rust. Just prev.sd; the wasix
# rustPlatform builds it, installs the .wasm, and sets the eh profile + meta.
{exposeExtendedPackage}:
# No emulatedCheck: sd's proptest dep and sd-cli's assert_cmd dep both pull
# wait-timeout, whose imp module is cfg(unix)/cfg(windows) only, so it fails
# to compile (unresolved `imp`) for wasm32-wasix.
exposeExtendedPackage {passthru.wasinix.shipped = true;}
