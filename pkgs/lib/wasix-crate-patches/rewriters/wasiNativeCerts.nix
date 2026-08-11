# Extends rustls-native-certs' Unix certificate-store cfg to WASI. Versions
# before 0.8.4 use this layout; later versions have a distinct backend patch.
# Runs against $PWD and fails unless both expected source shapes occur.
{writers}:
writers.writePython3 "wasiNativeCerts" {flakeIgnore = ["E501"];} ''
  from pathlib import Path


  replacements = (
      (
          Path("Cargo.toml"),
          "cfg(all(unix, not(target_os = \"macos\")))",
          "cfg(any(all(unix, not(target_os = \"macos\")), target_os = \"wasi\"))",
          1,
      ),
      (
          Path("src/lib.rs"),
          'all(unix, not(target_os = "macos"))',
          'any(all(unix, not(target_os = "macos")), target_os = "wasi")',
          2,
      ),
  )

  for path, old, new, expected in replacements:
      before = path.read_text(encoding="utf-8")
      count = before.count(old)
      if count != expected:
          raise SystemExit(
              f"wasiNativeCerts: expected {expected} matches in {path}, found {count}"
          )
      path.write_text(before.replace(old, new), encoding="utf-8")
''
