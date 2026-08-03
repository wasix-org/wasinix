# Narrows every `target_arch = "wasm32"` cfg gate (and its negation, and an
# explicit linux/macos/windows allowlist) to exclude `target_vendor = "wasmer"`,
# so wasmer takes the crate's native branch instead of its browser-wasm one.
# Runs against the unpacked crate dir ($PWD) and fails loud if it matches nothing.
{writers}:
writers.writePython3 "wasmerAsNative" {flakeIgnore = ["E501" "E302" "E305"];} ''
  import glob

  # both bare (rust source) and TOML-escaped (Cargo.toml target tables) quotes;
  # a stash keeps the negated form from being re-touched by the positive pass.
  def narrow(text):
      for stash, q in (("\0NEG\0", '"'), ("\0NEGE\0", '\\"')):
          text = text.replace(f"not(target_arch = {q}wasm32{q})", stash)
          text = text.replace(
              f"target_arch = {q}wasm32{q}",
              f"all(target_arch = {q}wasm32{q}, not(target_vendor = {q}wasmer{q}))",
          )
          text = text.replace(
              stash,
              f"any(not(target_arch = {q}wasm32{q}), target_vendor = {q}wasmer{q})",
          )
          text = text.replace(
              f"not(any(target_os = {q}linux{q}, target_os = {q}macos{q}, target_os = {q}windows{q}))",
              f"not(any(target_os = {q}linux{q}, target_os = {q}macos{q}, target_os = {q}windows{q}, target_vendor = {q}wasmer{q}))",
          )
      return text

  changed = False
  for pattern in ("Cargo.toml", "**/*.rs"):
      for path in glob.glob(pattern, recursive=True):
          with open(path, encoding="utf-8") as fh:
              before = fh.read()
          after = narrow(before)
          if after != before:
              with open(path, "w", encoding="utf-8") as fh:
                  fh.write(after)
              changed = True

  if not changed:
      raise SystemExit("wasmerAsNative: no target_arch = \"wasm32\" gate to narrow")
''
