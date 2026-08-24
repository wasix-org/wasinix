# libdd-http-client: a Cargo.toml feature-default flip selecting the hyper
# backend over the browser (wasm-bindgen/fetch) one; a pure residual patch, no
# cfg rewrite needed.
_: {
  edited = ["*"];
  notMinted = "git-sourced via ddtrace (DataDog/libdatadog), not crates.io";
  forVersion = _: {
    patches = [./hyper-backend.patch];
  };
}
