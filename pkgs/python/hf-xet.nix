# hf-xet gates its transfer engine, runtime and config off for target_family =
# "wasm", which also matches wasi despite wasi having threads, fs and sockets, so
# the seds narrow every wasm gate to the browser target. The shared Rust platform
# applies the WASIX crate edits and amends the lock for dependencies they add.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.hf-xet {
  patches = [./patches/hf-xet-wasi-sigint.patch];
  postPatch = ''
    chmod -R u+w ..
    find .. \( -name '*.rs' -o -name Cargo.toml \) -type f -print0 | xargs -0 sed -i \
      -e 's/target_family = "wasm"/all(target_family = "wasm", target_os = "unknown")/g' \
      -e 's/target_arch = "wasm32"/all(target_arch = "wasm32", target_os = "unknown")/g'
  '';
  # aws-lc-sys minus its two wasi-incompatible sources: jitterentropy needs a
  # hi-res timer, and console.c's tty branch needs the sigaction/fileno that
  # wasix-libc hides from strict -std=c11 without _GNU_SOURCE.
  env = {
    AWS_LC_SYS_NO_JITTER_ENTROPY = "1";
    AWS_LC_SYS_CFLAGS = "-DOPENSSL_NO_TTY -D_GNU_SOURCE";
  };
}
