# Narrows every `target_arch = "wasm32"` cfg gate (and its negation, and an
# explicit linux/macos/windows allowlist) to exclude `target_vendor = "wasmer"`,
# so wasmer takes the crate's native branch instead of its browser-wasm one.
# Runs against the unpacked crate dir ($PWD) and fails loud when a crate names a
# wasm target it could not rewrite.
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
  mentions_wasm = False
  for pattern in ("Cargo.toml", "**/*.rs"):
      for path in glob.glob(pattern, recursive=True):
          with open(path, encoding="utf-8") as fh:
              before = fh.read()
          mentions_wasm = mentions_wasm or "wasm" in before
          after = narrow(before)
          if after != before:
              with open(path, "w", encoding="utf-8") as fh:
                  fh.write(after)
              changed = True

  # A crate that names no wasm target at all keeps its native branch
  # unconditionally, which is what narrowing aims for; one that names a wasm
  # target we did not rewrite spells its gate some way this does not know.
  if not changed and mentions_wasm:
      raise SystemExit("wasmerAsNative: wasm is named but no gate matched, so the spelling moved")
''
