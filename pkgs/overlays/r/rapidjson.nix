# rapidjson builds its tests and docs by default; a cross build runs neither,
# and the doc pass wants doxygen and graphviz.
{
  exposeWasixExtendedPackage,
  dropInputsByName,
}:
exposeWasixExtendedPackage {
  cmakeFlags = [
    "-DRAPIDJSON_BUILD_TESTS=OFF"
    "-DRAPIDJSON_BUILD_DOC=OFF"
  ];
  passthru.wasinix.checks.link.source = ''
    #include <rapidjson/document.h>

    int main() {
      rapidjson::Document document;
      document.Parse("{\"wasix\":true}");
      return document.HasParseError();
    }
  '';
  buildInputs = dropInputsByName ["gtest"];
  doCheck = false;
}
