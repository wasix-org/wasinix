{
  wheel,
  harnesses,
  ...
}: {
  openssl-provider = harnesses.python {
    name = "cryptography-openssl-provider";
    inherit wheel;
    script = ''
      from cryptography.hazmat.bindings import _rust
      from cryptography.hazmat.primitives import hashes

      assert isinstance(_rust.openssl.is_fips_enabled(), bool)
      digest = hashes.Hash(hashes.SHA256())
      digest.update(b"wasix")
      assert len(digest.finalize()) == 32
    '';
  };
}
