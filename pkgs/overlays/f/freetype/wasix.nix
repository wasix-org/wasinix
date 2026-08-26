# zlib + libpng auto-thread (same-profile). We don't build harfbuzz for wasm;
# freetype's configure otherwise auto-detects it and aborts.
{
  exposeWasixExtendedPackage,
  packages,
}:
exposeWasixExtendedPackage {
  configureFlags = ["--with-harfbuzz=no"];
  propagatedBuildInputs = _: [packages.sameProfile.zlib packages.sameProfile.libpng];
  postInstall = _: "";
}
