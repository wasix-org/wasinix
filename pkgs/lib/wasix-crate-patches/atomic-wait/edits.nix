# atomic-wait dispatches its futex backend per OS and has no wasi arm, leaving
# `platform` undefined. The floor adds one over the wasm atomics instructions
# (memory.atomic.wait32 / notify), which is what the linux futex calls map to.
# Those intrinsics are unstable, so the arm carries its own feature gate; the
# wasix rustc is a nightly fork, which is what makes that legal.
_: {
  edited = [">=1.1.0"];
}
