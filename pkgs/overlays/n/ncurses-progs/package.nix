{
  exposePackage,
  packageSet,
}:
exposePackage (
  (packageSet.ncurses.override {
    enableStatic = true;
    withCxx = false;
  }).overrideAttrs (_old: {pname = "ncurses-progs";})
)
