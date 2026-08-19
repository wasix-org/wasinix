# libedit refuses to build unless __STDC_ISO_10646__ says wchar_t holds
# Unicode. wasi-libc defines it in stdc-predef.h, which gcc includes on its own
# and clang does not, so the header has to be named (WASIX-TODO.md). vi mode's
# `v` opens the line in $EDITOR through fork, which has no wasi equivalent.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  env.NIX_CFLAGS_COMPILE = "-include stdc-predef.h";
  patches = [./patches/wasi-no-editor-escape.patch];
  # the example programs fork; nothing installs them
  configureFlags = ["--disable-examples"];
}
prev.libedit
