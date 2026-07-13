# Patch vendored getrandom 0.3/0.4 so our wasix target uses their WASI Preview 1
# backend instead of the component-model one (which compile_error!s with
# "Unknown version of WASI"). Both versions' `wasi_p1` backend is a raw
# `extern "C" random_get` from wasi_snapshot_preview1 (which wasix libc provides)
# with no crate dependency, and both gate it behind `#[cfg(target_env = "p1")]`
# as the first arm of their wasi selection — so flipping that arm to "anything
# but p2/p3" routes our env to wasi_p1. No fork needed (unlike the wasix crate
# path the getrandom fork uses); just refresh src/backends.rs + its checksum.
#
# Proper upstream fix: our wasix rust target should report `target_env = "p1"`
# (wasix is preview1-compatible for random_get); then getrandom picks wasi_p1
# on its own. Until the target spec sets that, this vendor patch stands in.
#
# Crates live at depth 1 (importCargoLock's flat cargo-vendor-dir) or depth 2
# (fetchCargoVendor's source-registry-0/); importCargoLock symlinks the crates,
# so dereference with `cp -rL`. Fails loudly if the selection block moves.
# `pkgs` is the build-platform package set.
{pkgs}: cargoDeps:
pkgs.runCommand cargoDeps.name {} ''
  cp -rL ${cargoDeps} $out
  chmod -R +w $out
  patched=
  while IFS= read -r d; do
    f="$d/src/backends.rs"
    [ -f "$f" ] || continue
    grep -q 'if #\[cfg(target_env = "p1")\] {' "$f" \
      || { echo "getrandom backends.rs selection changed — update vendor-getrandom-wasi.nix" >&2; exit 1; }
    # p1 and our env -> wasi_p1 (raw preview1 random_get); p2/p3 keep their backend.
    sed -i 's/if #\[cfg(target_env = "p1")\] {/if #[cfg(not(any(target_env = "p2", target_env = "p3")))] {/' "$f"
    new=$(sha256sum "$f" | cut -d' ' -f1)
    ${pkgs.jq}/bin/jq --arg h "$new" '.files["src/backends.rs"]=$h' \
      "$d/.cargo-checksum.json" > "$d/.cargo-checksum.json.new"
    mv "$d/.cargo-checksum.json.new" "$d/.cargo-checksum.json"
    patched=1
  done < <(find $out -maxdepth 2 -type d -regex '.*/getrandom-0\.[34]\..*')
  [ -n "$patched" ] || { echo "no vendored getrandom-0.3/0.4 to patch" >&2; exit 1; }
''
