# rapidjson builds its tests and docs by default; a cross build runs neither,
# and the doc pass wants doxygen and graphviz.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.rapidjson {
  cmakeFlags = [
    "-DRAPIDJSON_BUILD_TESTS=OFF"
    "-DRAPIDJSON_BUILD_DOC=OFF"
  ];
  passthru.wasix.smokeTest.source = ''
    #include <rapidjson/document.h>

    int main() {
      rapidjson::Document document;
      document.Parse("{\"wasix\":true}");
      return document.HasParseError();
    }
  '';
  buildInputs = helpers.dropInputsByName ["gtest"];
  doCheck = false;
}
