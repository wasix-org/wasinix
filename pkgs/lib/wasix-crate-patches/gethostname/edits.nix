# Only unix and windows get a `gethostname_impl`, so a wasm build fails to
# resolve the call; the added arm calls wasix-libc's gethostname directly. 0.5
# and 1.x still carry just those two arms and need the same edit, but the floor
# does not fit their tree, so they are left as they are until one is resolved.
{...}: {
  edited = ["=0.4.3"];
  stock = ["<0.4.3" ">0.4.3"];
}
