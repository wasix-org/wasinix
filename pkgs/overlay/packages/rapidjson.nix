# rapidjson builds its tests and docs by default; a cross build runs neither,
# and the doc pass wants doxygen and graphviz.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  cmakeFlags = [
    "-DRAPIDJSON_BUILD_TESTS=OFF"
    "-DRAPIDJSON_BUILD_DOC=OFF"
  ];
  buildInputs = helpers.dropInputsByName ["gtest"];
  doCheck = false;
}
prev.rapidjson
