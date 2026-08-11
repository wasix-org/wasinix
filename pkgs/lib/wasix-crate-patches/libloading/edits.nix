# WASIX dynamic-linking hosts expose the POSIX dlopen API without cfg(unix), so
# the floor opens the unix backend to the wasm family. That backend uses cfg-if,
# which upstream declares only for unix and windows, so the manifest edit rides
# along; without it the extern crate resolves to the sysroot's private copy.
{...}: {
  edited = [">=0.8.9"];
}
