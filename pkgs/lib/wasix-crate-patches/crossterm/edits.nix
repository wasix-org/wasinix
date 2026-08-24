# crossterm dispatches its `sys` module on unix vs windows, so a wasm target
# gets neither and the terminal queries resolve to nothing. The floor adds a
# wasi backend: WASI has no termios and no window-size ioctl, so raw mode is
# refused and the size is the conventional 80x24. Only what comfy-table's table
# layout reaches is implemented.
_: {
  edited = ["=0.28.1" ">=0.29.0"];
}
