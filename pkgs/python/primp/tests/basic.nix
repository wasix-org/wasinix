# primp under wasmer: prove the aws-lc-rs TLS stack (the reason for the aws-lc-sys
# port) initializes, offline.
{
  wheel,
  runPython,
  ...
}: {
  # Client construction builds the rustls ClientConfig on the aws-lc-rs crypto
  # provider plus the browser TLS fingerprint; then a header roundtrip through
  # the rust request builder. No network (the sandbox has none).
  client = runPython {
    name = "primp-client";
    inherit wheel;
    script = ''
      import primp

      client = primp.Client(impersonate="chrome_146")
      client.headers = {"x-test": "primp"}
      assert client.headers.get("x-test") == "primp", client.headers
    '';
  };
}
