# Splits a generated Cargo.toml's broad WASI dependency into unknown-vendor
# `wasi` and Wasmer-vendor `wasix` dependencies. Preserves the upstream `wasi`
# requirement and fails unless exactly one expected dependency block exists.
{writers}:
writers.writePython3 "wasiVendorDeps" {flakeIgnore = ["E501" "E302" "E305"];} ''
  import re
  import sys
  from pathlib import Path


  if len(sys.argv) != 2:
      raise SystemExit("usage: wasiVendorDeps WASIX_VERSION")

  wasix_version = sys.argv[1]
  manifest = Path("Cargo.toml")
  text = manifest.read_text(encoding="utf-8")
  wasi_header = "[target.'cfg(target_os = \"wasi\")'.dependencies.wasi]\n"
  wasi = re.escape(wasi_header) + 'version = "([^"]+)"\n'

  matches = list(re.finditer(wasi, text))
  if len(matches) != 1:
      raise SystemExit(
          f"wasiVendorDeps: expected one broad WASI dependency, found {len(matches)}"
      )

  unknown = (
      "[target.'cfg(all(target_os = \"wasi\", target_vendor = \"unknown\"))'.dependencies.wasi]\n"
      f'version = "{matches[0].group(1)}"\n\n'
  )
  wasmer = (
      "[target.'cfg(all(target_os = \"wasi\", target_vendor = \"wasmer\"))'.dependencies.wasix]\n"
      f'version = "{wasix_version}"\n'
  )

  # Some generated manifests put a WASI-only libc block immediately before the
  # dependency. Keep the split dependencies ahead of that adjacent block.
  libc_header = "[target.'cfg(target_os = \"wasi\")'.dependencies.libc]\n"
  libc = re.escape(libc_header) + 'version = "([^"]+)"\n\n'
  pair = re.compile(libc + wasi)
  pair_matches = list(pair.finditer(text))
  if pair_matches:
      if len(pair_matches) != 1:
          raise SystemExit(
              f"wasiVendorDeps: expected at most one WASI libc pair, found {len(pair_matches)}"
          )
      libc_version = pair_matches[0].group(1)
      replacement = (
          f"{unknown}{wasmer}\n"
          "[target.'cfg(target_os = \"wasi\")'.dependencies.libc]\n"
          f'version = "{libc_version}"\n'
      )
      text = pair.sub(replacement, text, count=1)
  else:
      text = re.sub(wasi, unknown + wasmer, text, count=1)

  manifest.write_text(text, encoding="utf-8")
''
