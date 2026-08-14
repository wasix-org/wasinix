let
  versions = import ./versions.nix;
  versionNames = builtins.attrNames versions;
in {
  names = ["php"] ++ versionNames;
  packages = {
    final,
    prev,
    helpers,
    ...
  }: let
    lib = prev.lib;
    getDev = lib.getDev;

    pharPhp = (final.buildPackages.php.override {
      cgiSupport = false;
      fpmSupport = false;
      pearSupport = false;
      phpdbgSupport = false;
      valgrindSupport = false;
    }).unwrapped.overrideAttrs (_: {separateDebugInfo = false;});

    libpqLibraryDir = "${getDev final.libpq}/lib";
    libpqPrefix = final.buildPackages.runCommand "php-libpq-prefix" {} ''
      mkdir -p "$out/include" "$out/lib"
      cp -a ${getDev final.libpq}/include/. "$out/include/"
      cp -a ${libpqLibraryDir}/. "$out/lib/"
    '';

    buildInputs = [
      final.brotli
      final.curl
      final.freetype
      final.html-tidy
      final.icu
      final.imagemagick
      final.libdeflate
      final.libiconv
      final.libjpeg
      final.libpng
      final.libpq
      final.libsodium
      final.libtiff
      final.libwebp
      final.libxml2
      final.libzip
      final.lcms2
      final.oniguruma
      final.openjpeg
      final.openssl
      final.sqlite
      final.xz
      final.zlib
      final.zstd
    ];

    configureFlags = spec:
      [
        "--enable-bcmath"
        "--enable-exif"
        "--enable-fd-setsize=8192"
        "--enable-ftp"
        "--enable-gd"
        "--enable-igbinary"
        "--enable-intl"
        "--enable-mbregex"
        "--enable-mbstring"
        "--enable-opcache"
        "--enable-soap"
        "--enable-static"
        "--disable-cgi"
        "--disable-huge-code-pages"
        "--disable-phpdbg"
        "--disable-rpath"
        "--disable-shared"
        "--disable-zend-signals"
        "--with-curl"
        "--with-freetype"
        "--with-iconv"
        "--with-imagick"
        "--with-jpeg"
        "--with-mysqli=mysqlnd"
        "--with-openssl"
        "--with-pcre-jit=no"
        "--with-pdo-mysql=mysqlnd"
        "--with-pdo-pgsql=${libpqPrefix}"
        "--with-pdo-sqlite"
        "--with-pgsql=${libpqPrefix}"
        "--with-sodium"
        "--with-tidy=${final.html-tidy}"
        "--with-valgrind=no"
        "--with-webp"
        "--with-zip"
        "--with-zlib"
      ]
      ++ lib.optional (lib.versionAtLeast spec.version "8.0") "--disable-opcache-jit"
      ++ lib.optional (lib.versionAtLeast spec.version "8.1") "--enable-fiber-asm";

    mkPhp = webcName: spec:
      helpers.wasmRename {wasmName = "php";} (final.stdenv.mkDerivation {
        pname = "php";
        inherit (spec) version;

        src = final.fetchFromGitHub {
          owner = "wasix-org";
          repo = "php";
          inherit (spec) rev hash;
        };

        patches = lib.optionals (lib.versionOlder spec.version "8.0") [
          ./patches/php74-cross-phar.patch
          ./patches/php74-libxml-2.15.patch
        ];

        nativeBuildInputs =
          (with final.buildPackages; [
            autoconf
            automake
            bison
            flex
            libtool
            pkg-config
            re2c
          ])
          ++ [final.disableWasmOptInConfigureHook];
        inherit buildInputs;
        configureFlags = configureFlags spec;

        postPatch = lib.optionalString (lib.versionOlder spec.version "8.0") ''
          substituteInPlace ext/phar/Makefile.frag \
            --replace-fail '@PHP_PHARCMD_EXECUTABLE@' '${pharPhp}/bin/php'
        '';

        enableParallelBuilding = true;

        env = {
          CFLAGS = "-std=gnu17 -O2";
          CXXFLAGS = "-O2";
          ICONV_LIBS = "-liconv -lcharset -licrt";
          ICU_CFLAGS = "-I${getDev final.icu}/include -std=c11";
          ICU_CXXFLAGS = "-I${getDev final.icu}/include -std=c++17";
          ICU_LIBS = "-licudata -licui18n -licuio -licuuc";
          IM_IMAGEMAGICK_CFLAGS = "-I${getDev final.imagemagick}/include/ImageMagick -DIM_MAGICKWAND_HEADER_STYLE_SEVEN -DMAGICKCORE_QUANTUM_DEPTH=16 -DMAGICKCORE_HDRI_ENABLE=1 -DMAGICKCORE_CHANNEL_MASK_DEPTH=32";
          IM_IMAGEMAGICK_LIBS = "-lMagickWand-7.Q16HDRI -lMagickCore-7.Q16HDRI -ltiff -lz -ldeflate -ljpeg -llzma -lzstd -lpng16 -lwebpmux -lwebpdemux -lwebp -lsharpyuv -lfreetype -lxml2 -lcurl -lssl -lcrypto";
          LIBS = "-L${libpqLibraryDir} -lpgcommon -lpgport -lm";
          PGSQL_CFLAGS = "-I${libpqPrefix}/include";
          PGSQL_LIBS = "-lpq -lpgcommon -lpgport -lz -lm";
          PHP_BUILD_SYSTEM = "clang(WASIX+WasmEH)";
          PHP_IPV6 = "yes";
          PROG_SENDMAIL = "/usr/bin/sendmail";
          WASIXCC_INCLUDE_CPP_SYMBOLS = "yes";
          WASIXCC_WASM_OPT_FLAGS =
            if lib.versionOlder spec.version "8.0"
            then "--experimental-new-eh:--pass-arg=max-func-params@32:--fpcast-emu:-O2"
            else "--experimental-new-eh:-O2";
          ac_cv_lib_pq_PQchangePassword = "yes";
          ac_cv_lib_pq_PQencryptPasswordConn = "yes";
          ac_cv_lib_pq_PQlibVersion = "yes";
          ac_cv_lib_pq_PQsetErrorContextVisibility = "yes";
          ac_cv_lib_pq_PQsocketPoll = "yes";
          ac_cv_lib_pq_lo_truncate64 = "yes";
          ac_cv_lib_pq_pg_encoding_to_char = "yes";
        };

        preConfigure = ''
          patchShebangs buildconf build scripts
          export CURL_LIBS="$(${getDev final.curl}/bin/curl-config --static-libs) -ldl -pthread"
          ./buildconf --force
        '';

        postInstall = ''
          install -Dm644 php.ini-production "$out/lib/php.ini"
        '';

        passthru = {
          wasix = {
            shipped = true;
            supportedProfiles = ["exnrefEh"];
          };
          wasmer = {
            name = webcName;
            entrypoint = "php";
            commands = [
              {
                name = "php";
                module = "php";
                wasm = "php.wasm";
              }
            ];
            autoSelfMount = true;
          };
        };

        meta = {
          description = "PHP ${spec.version} interpreter for WASIX";
          homepage = "https://github.com/wasix-org/php";
          license = lib.licenses.php301;
          mainProgram = "php";
        };
      });
  in
    lib.mapAttrs (name: spec: mkPhp name spec) versions
    // {php = mkPhp "php" versions.php85;};
}
