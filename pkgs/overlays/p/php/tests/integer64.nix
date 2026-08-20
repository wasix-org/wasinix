{
  crossPkgs,
  helpers,
  makeWasmerPackage,
  pkgs,
  testLib,
  ...
}: let
  versions = import ../versions.nix;
  wasmerPkgs = helpers.mkPhpShims "-int64" {inherit crossPkgs makeWasmerPackage;};
in
  pkgs.lib.mapAttrs' (attr: _:
    pkgs.lib.nameValuePair "${attr}-int64" (testLib.mkWasixRun {
      name = "${attr}-int64";
      wasixPkgs = [wasmerPkgs.${attr}];
      script = ''
        php -r '
          if (PHP_INT_SIZE !== 8 || PHP_INT_MAX !== 9223372036854775807 || PHP_INT_MIN !== -9223372036854775807 - 1) {
              throw new RuntimeException("wrong integer range");
          }
          if ((int) "2147483648" !== 2147483648) {
              throw new RuntimeException("32-bit boundary failed");
          }
          if ((1 << 40) !== 1099511627776 || intdiv(PHP_INT_MAX, 2147483648) !== 4294967295) {
              throw new RuntimeException("64-bit arithmetic failed");
          }
          $key = 4294967296;
          $keyed = [$key => "value"];
          if (!isset($keyed[$key]) || array_key_first($keyed) !== $key) {
              throw new RuntimeException("64-bit array key failed");
          }
          $integers = [PHP_INT_MIN, -2147483649, 2147483648, PHP_INT_MAX];
          if (unserialize(serialize($integers)) !== $integers) {
              throw new RuntimeException("native serialization failed");
          }
          if (json_decode("[9223372036854775807]", true) !== [PHP_INT_MAX]) {
              throw new RuntimeException("JSON integer decoding failed");
          }
          if ((new DateTimeImmutable("@4102444800"))->getTimestamp() !== 4102444800) {
              throw new RuntimeException("post-2038 timestamp failed");
          }
          if ((new DateTimeImmutable("@-2208988800"))->getTimestamp() !== -2208988800) {
              throw new RuntimeException("pre-1901 timestamp failed");
          }
          $sqlite = new SQLite3(":memory:");
          $sqlite->exec("CREATE TABLE integers (value INTEGER)");
          $statement = $sqlite->prepare("INSERT INTO integers VALUES (:value)");
          $statement->bindValue(":value", PHP_INT_MAX, SQLITE3_INTEGER);
          $statement->execute();
          $row = $sqlite->querySingle("SELECT value FROM integers");
          if ($row !== PHP_INT_MAX) {
              throw new RuntimeException("SQLite3 integer round trip failed");
          }
          if (igbinary_unserialize(igbinary_serialize($integers)) !== $integers) {
              throw new RuntimeException("igbinary 64-bit round trip failed");
          }
          if (!extension_loaded("imagick")) {
              throw new RuntimeException("imagick is not loaded");
          }
        '
      '';
    }))
  versions
