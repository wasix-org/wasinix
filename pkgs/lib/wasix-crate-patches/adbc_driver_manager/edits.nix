# adbc_driver_manager gates its dlopen path and its config-dir lookups on unix,
# so a wasm target defines neither the loaded library nor a return value. WASIX
# has dlopen (the libloading floor opens os::unix to it) and reads the same
# XDG_CONFIG_HOME/HOME, so both gates just need the wasi arm.
{...}: {
  edited = [">=0.22.0"];
  notMinted = "git-sourced via dbt (dbt-labs/arrow-adbc), not crates.io";
}
