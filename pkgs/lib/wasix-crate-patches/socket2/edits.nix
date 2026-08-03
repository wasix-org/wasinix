# socket2: version-pinned wasi backend on the 0.6.x line, absorbed upstream at
# 0.6.3, so 0.6.3+ is stock (a durable upstream fix) and 0.6.0-0.6.2 take the
# floor patch. The pre-0.6 line is a different backend and builds stock (main
# builds every 0.5.x consumer unpatched).
{...}: {
  edited = [">=0.6.0, <0.6.3"];
  stock = [">=0.6.3" "<0.6.0"];
}
