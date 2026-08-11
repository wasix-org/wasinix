# `open` launches a path in the desktop handler and refuses to compile on a
# platform it has no launcher for. The floor adds a wasi arm shaped like the
# redox one: there is no desktop under wasmer, so the spawn fails at runtime
# with the launcher missing rather than failing the build.
{...}: {
  edited = [">=5.4.0"];
}
