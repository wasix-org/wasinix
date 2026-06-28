# zlib + libpng auto-thread (same-profile). We don't build harfbuzz for wasm;
# freetype's configure otherwise auto-detects it and aborts.
{
  final,
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  configureFlags = ["--with-harfbuzz=no"];
  propagatedBuildInputs = _: [final.zlib final.libpng];
  postInstall = _: "";
}
prev.freetype
