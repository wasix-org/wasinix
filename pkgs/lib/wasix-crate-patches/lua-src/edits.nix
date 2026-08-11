# lua-src matches the target to pick Lua's platform defines and panics on one it
# does not know. WASIX has the POSIX surface Lua wants (the emscripten arm picks
# the same define), so the floor adds the wasi arm.
{...}: {
  edited = [">=547.0.0"];
}
