# static-web-server's default feature set includes HTTP/2 over TLS. Wasmer Edge
# terminates TLS before the guest, so omit http2-ring. Directory-listing downloads
# pull async-tar's async-std/polling stack, which has no WASI backend; ordinary
# directory listings remain enabled.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./wasix.patch];
  postPatch = ''
    substituteInPlace Cargo.toml \
      --replace-fail 'shadow-rs = "1.4.0"' 'shadow-rs = { version = "1.4.0", default-features = false, features = ["build"] }'
  '';
  passthru.wasix = {
    shipped = true;
    updateNotes = [
      {message = "recheck or drop wasix.patch; it supplies missing WASI cfg branches for paths and signal-free shutdown";}
    ];
  };
} (prev.static-web-server.overrideAttrs (_: {
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
}))
