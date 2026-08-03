# libdd-http-client: a Cargo.toml feature-default flip selecting the hyper
# backend over the browser (wasm-bindgen/fetch) one; a pure residual patch, no
# cfg rewrite needed.
{...}: {
  edited = ["*"];
  notMinted = "git-sourced via ddtrace (DataDog/libdatadog), not crates.io";
  forVersion = {...}: {
    patches = [./hyper-backend.patch];
  };
}
