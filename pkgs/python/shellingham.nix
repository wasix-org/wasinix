# nixpkgs' postPatch bakes procps' `ps` into the posix backend; on wasi that
# interpolation hits infinite recursion inside nixpkgs (unixtools.procps
# resolves back to pkgs.procps). Keep upstream's plain "ps" PATH lookup;
# shellingham degrades gracefully without ps.
{
  exposePackage,
  package,
}:
exposePackage (
  package.overridePythonAttrs (_old: {
    postPatch = "";
  })
)
