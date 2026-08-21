# libavif propagates gdk-pixbuf and glib, which does not build here
# (WASIX-TODO.md), and glib's setup hook arrives as a bare path that buildEnv
# rejects. The xpm reader pulls xorgproto, whose XFD_ macros want a bitmask
# fd_set where wasi's is a descriptor list. Every other codec stays.
{
  exposePackage,
  extendPackage,
  package,
  dropInputsByName,
}:
exposePackage (
  extendPackage (package.override {withXorg = false;}) {
    propagatedBuildInputs = dropInputsByName ["libavif"];
  }
)
