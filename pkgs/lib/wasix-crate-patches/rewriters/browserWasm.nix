# Narrows the browser gate to `all(target_arch = "wasm32", target_os = "unknown")`
# so only wasm32-unknown-unknown is browser and wasi/wasmer takes the native
# branch (reqwest's fetch-vs-hyper backend). Runs against $PWD, fails loud.
{writers}:
writers.writePython3 "browserWasm" {flakeIgnore = ["E501" "E302" "E305"];} ''
  import glob

  def narrow(text):
      for stash, q in (("\0NEG\0", '"'), ("\0NEGE\0", '\\"')):
          text = text.replace(f"not(target_arch = {q}wasm32{q})", stash)
          text = text.replace(
              f"target_arch = {q}wasm32{q}",
              f"all(target_arch = {q}wasm32{q}, target_os = {q}unknown{q})",
          )
          text = text.replace(
              stash,
              f"not(all(target_arch = {q}wasm32{q}, target_os = {q}unknown{q}))",
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
      raise SystemExit("browserWasm: no target_arch = \"wasm32\" gate to narrow")
''
