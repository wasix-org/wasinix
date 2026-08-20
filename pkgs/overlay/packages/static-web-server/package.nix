# static-web-server's default feature set includes HTTP/2 over TLS. Wasmer Edge
# terminates TLS before the guest, so omit http2-ring. Directory-listing downloads
# pull async-tar's async-std/polling stack, which has no WASI backend; ordinary
# directory listings remain enabled.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage (prev.static-web-server.overrideAttrs (_: {
  # This wraps an existing buildRustPackage result, so set the hook variables
  # produced by buildRustPackage rather than its already-consumed arguments.
  cargoBuildNoDefaultFeatures = true;
  cargoBuildFeatures = [
    "compression"
    "directory-listing"
    "basic-auth"
    "fallback-page"
    "metrics"
  ];

  # These units launch a native binary and are not part of the webc payload.
  postInstall = "";
})) {
  patches = [./wasix.patch];
  postPatch = ''
    substituteInPlace Cargo.toml \
      --replace-fail 'shadow-rs = "2.0.0"' 'shadow-rs = { version = "2.0.0", default-features = false, features = ["build"] }'
  '';
  passthru.wasix = {
    shipped = true;
    updateNotes = [
      {message = "recheck the mio WASIX backend patch if Cargo.lock moves off mio 1.2.1";}
      {message = "recheck the socket2 WASIX backend patch if Cargo.lock moves off socket2 0.5.10";}
      {message = "recheck the polling WASIX backend patch if Cargo.lock moves off polling 3.11.0";}
      {message = "recheck the async-io WASIX backend patch if Cargo.lock moves off async-io 2.6.0";}
      {message = "recheck the async-tar feature patch if Cargo.lock moves off async-tar 0.5.1";}
      {message = "recheck wasix.patch and the shadow-rs feature override on the next version bump";}
    ];
  };
  # Preserve the command identity published by wasix-org/static-web-server.
  # Edge deployments and SDK consumers address its atom explicitly as
  # `wasmer/static-web-server:webserver`, so changing it would break existing
  # package references even though the upstream binary has a different name.
  passthru.wasmer = {
    entrypoint = "webserver";
    commands = [
      {
        name = "webserver";
        module = "webserver";
        wasm = "static-web-server.wasm";
        output = "webserver.wasm";
      }
      # Also expose the upstream binary name for new consumers. Both commands
      # use the legacy module and atom, and therefore share one module in webc.
      {
        name = "static-web-server";
        module = "webserver";
        wasm = "static-web-server.wasm";
        output = "webserver.wasm";
      }
    ];
  };
}
