# Widens getrandom's WASI preview1 backend gate to cover custom preview1 target
# environments such as WASIX's `dl`, while leaving preview2/3 on their backends.
# Runs against $PWD and fails unless the expected generated cfg occurs once.
{writers}:
writers.writePython3 "wasiPreview1Env" {flakeIgnore = ["E501"];} ''
  from pathlib import Path


  path = Path("src/backends.rs")
  before = path.read_text(encoding="utf-8")
  old = 'if #[cfg(target_env = "p1")] {'
  new = 'if #[cfg(not(any(target_env = "p2", target_env = "p3")))] {'
  count = before.count(old)
  if count != 1:
      raise SystemExit(
          f"wasiPreview1Env: expected one preview1 backend gate, found {count}"
      )
  path.write_text(before.replace(old, new), encoding="utf-8")
''
