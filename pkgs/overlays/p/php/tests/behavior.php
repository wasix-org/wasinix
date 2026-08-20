<?php

function check_value($condition, $message)
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

$expectedVersion = $argv[1];
$font = $argv[2];
check_value(PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION . "." . PHP_RELEASE_VERSION === $expectedVersion, "wrong version");
check_value(PHP_INT_SIZE === 4, "wrong integer size");

$required = [
    "bcmath", "calendar", "curl", "dom", "fileinfo", "gd", "gettext",
    "gmp", "igbinary", "imagick", "intl", "json", "ldap", "mbstring",
    "mysqli", "openssl", "pdo_mysql", "pdo_odbc", "pdo_pgsql",
    "pdo_sqlite", "pgsql", "phar", "readline", "simplexml", "soap",
    "sockets", "sodium", "sqlite3", "tidy", "tokenizer", "xmlreader",
    "xmlwriter", "zip", "zlib", "Zend OPcache"
];
$missing = array_values(array_filter($required, static function ($extension) {
    return !extension_loaded($extension);
}));
check_value($missing === [], "missing extensions: " . implode(", ", $missing));

preg_match("/\\p{Greek}+/u", "wasix αβ", $matches);
check_value($matches[0] === "αβ", "PCRE Unicode matching failed");
check_value(json_decode(json_encode(["sum" => array_sum([1, 2, 3])]), true)["sum"] === 6, "JSON round trip failed");
check_value(hash("sha256", "wasix") === "b3aa2e295c5b1a5215bbb520f7dc33b20773cf7d08f659f441ee13fef67bb1b4", "hash failed");
check_value(strlen(random_bytes(32)) === 32, "random source failed");
check_value(bcadd("0.1", "0.2", 4) === "0.3000", "bcmath failed");
check_value(cal_days_in_month(CAL_GREGORIAN, 2, 2024) === 29, "calendar failed");
check_value(gettext("wasix") === "wasix", "gettext failed");
check_value(gmp_strval(gmp_add("40", "2")) === "42", "GMP failed");
check_value(mb_strtoupper("Grüße", "UTF-8") === "GRÜSSE", "mbstring failed");
check_value(mb_ereg("^[[:alpha:]]+$", "Wasix") !== false, "mbregex failed");
check_value(is_array(readline_info()), "readline failed");

$socket = socket_create(AF_INET, SOCK_DGRAM, SOL_UDP);
check_value($socket !== false, "socket creation failed");
socket_close($socket);

$xml = new DOMDocument();
check_value($xml->loadXML("<root><value>42</value></root>"), "DOM parse failed");
check_value($xml->getElementsByTagName("value")->item(0)->textContent === "42", "DOM traversal failed");
check_value((string) simplexml_load_string("<root><value>42</value></root>")->value === "42", "SimpleXML failed");
check_value(token_get_all("<?php echo 42;")[1][0] === T_ECHO, "tokenizer failed");

$work = getcwd() . "/behavior-work";
mkdir($work);
$path = $work . "/data.txt";
check_value(file_put_contents($path, "wasix\n") === 6, "file write failed");
$handle = fopen($path, "r+");
check_value($handle !== false, "file open failed");
check_value(stream_get_contents($handle) === "wasix\n", "stream read failed");
fclose($handle);
check_value(rename($path, $work . "/renamed.txt"), "rename failed");
check_value(filesize($work . "/renamed.txt") === 6, "stat failed");

$database = new PDO("sqlite:" . $work . "/pdo.sqlite");
$database->exec("create table values_table (value integer)");
$database->exec("insert into values_table values (40), (2)");
check_value((int) $database->query("select sum(value) from values_table")->fetchColumn() === 42, "PDO SQLite failed");
$pdoRows = $database->query("select value from values_table order by value")->fetchAll(PDO::FETCH_COLUMN);
check_value($pdoRows === ["2", "40"] || $pdoRows === [2, 40], "PDO SQLite rows failed");
$sqlite = new SQLite3($work . "/sqlite3.sqlite", SQLITE3_OPEN_CREATE | SQLITE3_OPEN_READWRITE);
$sqlite->enableExceptions(true);
$sqlite->exec("create table values_table (id integer primary key, value text not null)");
$sqlite->exec("insert into values_table values (1, 'foo'), (2, 'bar')");
$sqliteResult = $sqlite->query("select id, value from values_table order by id");
check_value($sqliteResult->fetchArray(SQLITE3_ASSOC) === ["id" => 1, "value" => "foo"], "SQLite3 first row failed");
check_value($sqliteResult->fetchArray(SQLITE3_ASSOC) === ["id" => 2, "value" => "bar"], "SQLite3 second row failed");
check_value($sqliteResult->fetchArray(SQLITE3_ASSOC) === false, "SQLite3 returned an extra row");

$image = imagecreatetruecolor(48, 32);
$red = imagecolorallocate($image, 220, 20, 60);
$green = imagecolorallocate($image, 30, 180, 70);
$blue = imagecolorallocate($image, 20, 80, 220);
imagefilledrectangle($image, 0, 0, 15, 31, $red);
imagefilledrectangle($image, 16, 0, 31, 31, $green);
imagefilledrectangle($image, 32, 0, 47, 31, $blue);
$png = $work . "/image.png";
check_value(imagepng($image, $png), "GD PNG encode failed");
$jpeg = $work . "/image.jpeg";
check_value(imagejpeg($image, $jpeg), "GD JPEG encode failed");
$webp = $work . "/image.webp";
check_value(imagewebp($image, $webp), "GD WebP encode failed");
$bmp = $work . "/image.bmp";
check_value(imagebmp($image, $bmp), "GD BMP encode failed");

$decodedImages = [
    "PNG" => imagecreatefrompng($png),
    "JPEG" => imagecreatefromjpeg($jpeg),
    "WebP" => imagecreatefromwebp($webp),
    "BMP" => imagecreatefrombmp($bmp)
];
foreach ($decodedImages as $format => $decoded) {
    check_value($decoded !== false, "GD " . $format . " decode failed");
    check_value(imagesx($decoded) === 48 && imagesy($decoded) === 32, "GD " . $format . " dimensions failed");
    foreach ([[8, 16, $red], [24, 16, $green], [40, 16, $blue]] as $sample) {
        [$x, $y, $expectedColor] = $sample;
        $actualColor = imagecolorat($decoded, $x, $y);
        foreach ([16, 8, 0] as $shift) {
            $expectedChannel = ($expectedColor >> $shift) & 0xff;
            $actualChannel = ($actualColor >> $shift) & 0xff;
            check_value(abs($actualChannel - $expectedChannel) <= 24, "GD " . $format . " pixels failed");
        }
    }
}

$textImage = imagecreatetruecolor(200, 40);
$background = imagecolorallocate($textImage, 255, 0, 0);
$foreground = imagecolorallocate($textImage, 0, 0, 0);
imagefill($textImage, 0, 0, $background);
$textBounds = imagefttext($textImage, 13, 0, 5, 25, $foreground, $font, "Testing FreeType");
check_value(is_array($textBounds) && count($textBounds) === 8, "GD FreeType bounds failed");
$changedPixels = 0;
for ($x = 0; $x < imagesx($textImage); $x++) {
    for ($y = 0; $y < imagesy($textImage); $y++) {
        if (imagecolorat($textImage, $x, $y) !== $background) {
            $changedPixels++;
        }
    }
}
check_value($changedPixels > 100, "GD FreeType rendering failed");

$imagick = new Imagick();
$imagick->newImage(3, 2, "rgb(12,34,56)");
$imagick->setImageFormat("png");
check_value(strlen($imagick->getImagesBlob()) > 20, "ImageMagick PNG encode failed");
check_value(Normalizer::normalize("e\u{0301}", Normalizer::FORM_C) === "é", "intl normalization failed");
$numberFormatter = new NumberFormatter("en_US", NumberFormatter::DECIMAL);
check_value($numberFormatter->format(1234.5) === "1,234.5", "intl locale data failed");
check_value(igbinary_unserialize(igbinary_serialize(["value" => 42]))["value"] === 42, "igbinary round trip failed");

$key = str_repeat("k", 32);
$iv = str_repeat("i", 16);
$encrypted = openssl_encrypt("wasix", "aes-256-cbc", $key, 0, $iv);
check_value(openssl_decrypt($encrypted, "aes-256-cbc", $key, 0, $iv) === "wasix", "OpenSSL cipher failed");
check_value(strlen(sodium_crypto_generichash("wasix")) === SODIUM_CRYPTO_GENERICHASH_BYTES, "sodium hash failed");

$tidy = new tidy();
$tidy->parseString("<html><body><p>wasix</body></html>");
$tidy->cleanRepair();
check_value(strpos((string) $tidy, "<p>wasix</p>") !== false, "tidy failed");
check_value((new SoapVar("wasix", XSD_STRING))->enc_value === "wasix", "SOAP value failed");

$zipPath = $work . "/archive.zip";
$zip = new ZipArchive();
check_value($zip->open($zipPath, ZipArchive::CREATE) === true, "ZIP create failed");
$zip->addFromString("value.txt", "42");
check_value($zip->setEncryptionName("value.txt", ZipArchive::EM_AES_256, "wasix"), "ZIP encryption failed");
$zip->close();
check_value($zip->open($zipPath) === true, "ZIP reopen failed");
$zip->setPassword("wasix");
check_value($zip->getFromName("value.txt") === "42", "ZIP round trip failed");
$zip->close();

$pharPath = $work . "/archive.phar";
$phar = new Phar($pharPath);
$phar->startBuffering();
$phar->addFromString("index.php", "<?php return 42;");
$phar->setStub($phar->createDefaultStub("index.php"));
$phar->stopBuffering();
check_value((include "phar://" . $pharPath . "/index.php") === 42, "PHAR execution failed");
check_value((new finfo(FILEINFO_MIME_TYPE))->file($png) === "image/png", "fileinfo failed");

echo "php behavior ok\n";
