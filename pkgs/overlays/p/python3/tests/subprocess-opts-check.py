# Run under python -O. The posix_spawn path guards Popen args it cannot
# express with asserts, which -O strips; each option must be either honored
# or refused with an exception, never silently dropped.
import os
import subprocess
import sys

failures = []

target = os.path.abspath("cwd-target")
os.makedirs(target, exist_ok=True)
try:
    res = subprocess.run(
        [sys.executable, "-c", "import os; print(os.getcwd())"],
        cwd=target,
        capture_output=True,
        text=True,
    )
    got = res.stdout.strip()
    if got != target:
        failures.append(f"cwd: child ran in {got!r} instead of {target!r}")
except Exception as e:
    print(f"cwd= refused with {type(e).__name__} (acceptable)")

r, w = os.pipe()
os.set_inheritable(w, True)
try:
    subprocess.run(
        [sys.executable, "-c", f"import os; os.write({w}, b'ok')"], pass_fds=[w]
    )
except Exception as e:
    print(f"pass_fds= refused with {type(e).__name__} (acceptable)")
    os.close(w)
else:
    os.close(w)
    data = os.read(r, 2)
    if data != b"ok":
        failures.append(f"pass_fds: child wrote {data!r} instead of b'ok'")

if failures:
    print("SUBPROC_OPTS_FAIL:", "; ".join(failures))
    sys.exit(1)
print("SUBPROC_OPTS_OK")
