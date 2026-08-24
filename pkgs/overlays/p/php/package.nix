let
  versions = import ./versions.nix;
  versionNames = builtins.attrNames versions;
  int64VersionNames = map (name: "${name}-int64") versionNames;
in {
  names = ["php" "php-int64"] ++ versionNames ++ int64VersionNames;
  packages = {
    final,
    prev,
    helpers,
    preferredProfilePackages,
    toolchain,
    ...
  }: let
    lib = prev.lib;
    getDev = lib.getDev;
    getLib = lib.getLib;
    libc = toolchain.variants.${helpers.profileOf prev.stdenv.hostPlatform}.libc;

    libintlPrefix = final.buildPackages.runCommand "php-libintl-prefix" {} ''
      mkdir -p "$out/include"
      cp ${libc}/include/libintl.h "$out/include/"
    '';

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

    ldapPrefix = final.buildPackages.runCommand "php-ldap-prefix" {} ''
      mkdir -p "$out/include" "$out/lib"
      cp -a ${getDev final.openldap}/include/. "$out/include/"
      cp -a ${getLib final.openldap}/lib/. "$out/lib/"
    '';

    baseBuildInputs = [
      final.brotli
      final.boost
      final.curl
      final.freetype
      final.gd
      final.gmp
      final.html-tidy
      final.icu
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
      final.openldap
      final.openssl
      final.pcre2
      final.readline
      final.sqlite
      final.unixodbc
      final.xz
      final.zlib
      final.zstd
    ];

    configureFlags = spec: enabledExtensions:
      [
        "--enable-bcmath"
        "--enable-calendar"
        "--enable-exif"
        "--enable-fd-setsize=8192"
        "--enable-ftp"
        "--enable-gd"
        "--enable-intl"
        "--enable-mbregex"
        "--enable-mbstring"
        "--enable-soap"
        "--enable-sockets"
        "--enable-static"
        "--disable-cgi"
        "--disable-huge-code-pages"
        "--disable-phpdbg"
        "--disable-rpath"
        "--disable-shared"
        "--disable-zend-signals"
        "--with-curl"
        "--with-external-gd=${getDev final.gd}"
        "--with-external-pcre=${getDev final.pcre2}"
        "--with-gettext=${libintlPrefix}"
        "--with-gmp=${getDev final.gmp}"
        "--with-iconv"
        "--with-ldap=${ldapPrefix}"
        "--with-mysqli=mysqlnd"
        "--with-openssl"
        "--with-pcre-jit=no"
        "--with-pdo-mysql=mysqlnd"
        "--with-pdo-odbc=unixODBC,${getDev final.unixodbc}"
        "--with-pdo-pgsql=${libpqPrefix}"
        "--with-pdo-sqlite"
        "--with-pgsql=${libpqPrefix}"
        "--with-readline=${getDev final.readline}"
        "--with-sodium"
        "--with-tidy=${final.html-tidy}"
        "--with-valgrind=no"
        "--with-zip"
        "--with-zlib"
      ]
      ++ map (extension: extension.configureFlag) enabledExtensions
      ++ lib.optional (lib.versionOlder spec.version "8.5") "--enable-opcache"
      ++ lib.optional (lib.versionAtLeast spec.version "8.0") "--disable-opcache-jit"
      ++ lib.optional (lib.versionAtLeast spec.version "8.1") "--enable-fiber-asm";

    defaultExtensionSelector = {enabled, ...}: enabled;

    mkPhp = webcName: spec: int64: history: extensionSelector: let
      serverSnapshot = lib.versionAtLeast spec.version "8.1";
      extensionPackages = import ./extensions.nix {
        inherit final lib;
        phpVersion = spec.version;
      };
      defaultExtensions = with extensionPackages; [
        igbinary
        imagick
      ];
      enabledExtensions = lib.unique (extensionSelector {
        enabled = defaultExtensions;
        all = extensionPackages;
      });
      extensionBuildInputs = lib.concatMap (extension: extension.buildInputs or []) enabledExtensions;
      extensionEnv = lib.foldl' lib.recursiveUpdate {} (map (extension: extension.env or {}) enabledExtensions);
      upstreamBaseline =
        ./tests/upstream-baselines
        + "/php${lib.versions.major spec.version}${lib.versions.minor spec.version}${lib.optionalString int64 "-int64"}.txt";
      src = final.fetchFromGitHub {
        owner = "php";
        repo = "php-src";
        inherit (spec) rev hash;
      };
      phpIni = final.buildPackages.runCommand "php-${spec.version}.ini" {} ''
        install -m644 ${src}/php.ini-production "$out"
        printf '%s\n' \
          'curl.cainfo = /etc/ssl/certs/ca-bundle.crt' \
          'openssl.cafile = /etc/ssl/certs/ca-bundle.crt' \
          'openssl.capath = /etc/ssl/certs' \
          'opcache.enable_cli = 1' \
          >> "$out"
      '';
      phpPatches = import ./patches {
        inherit lib int64 serverSnapshot;
        version = spec.version;
      };
    in
      helpers.wasmRename {wasmName = "php";} (final.stdenv.mkDerivation {
        pname = "php";
        inherit (spec) version;

        inherit src;

        patches = phpPatches.source;

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
        buildInputs = baseBuildInputs ++ extensionBuildInputs;
        configureFlags = configureFlags spec enabledExtensions;

        postPatch =
          lib.optionalString (lib.versionOlder spec.version "8.0") ''
            substituteInPlace ext/phar/Makefile.frag \
              --replace-fail '@PHP_PHARCMD_EXECUTABLE@' '${pharPhp}/bin/php'
          ''
          + lib.concatMapStringsSep "\n" (extension: ''
            mkdir -p ext/${extension.extensionName}
            cp -R --no-preserve=mode,ownership ${extension}/. ext/${extension.extensionName}/
          '')
          enabledExtensions
          + lib.optionalString (lib.versionAtLeast spec.version "8.1") ''
            cp ${./zend_fibers_wasix.cpp} Zend/zend_fibers_wasix.cpp
          '';

        enableParallelBuilding = true;
        doCheck = true;
        checkTarget = "test";
        wasixCheckPrebuild = ":";
        postBuild = lib.concatMapStringsSep "\n" (extension: extension.crossPostBuild or "") enabledExtensions;

        env =
          {
            CFLAGS = "-std=gnu17 -O2${lib.optionalString int64 " -DWASIX_64BIT_LONG_PATCH=1"}";
            CXXFLAGS = "-O2${lib.optionalString int64 " -DWASIX_64BIT_LONG_PATCH=1"}";
            ICONV_LIBS = "-liconv -lcharset -licrt";
            ICU_CFLAGS = "-I${getDev final.icu}/include -std=c11";
            ICU_CXXFLAGS = "-I${getDev final.icu}/include -std=c++17";
            ICU_LIBS = "-licudata -licui18n -licuio -licuuc";
            LIBS = "-L${libpqLibraryDir} -L${getLib final.boost}/lib -lpgcommon -lpgport -lboost_context -lm";
            PGSQL_CFLAGS = "-I${libpqPrefix}/include";
            PGSQL_LIBS = "-lpq -lpgcommon -lpgport -lz -lm";
            PHP_BUILD_SYSTEM =
              if lib.versionOlder spec.version "8.0"
              then "clang(WASIX+Asyncify)"
              else "clang(WASIX+WasmEH)";
            PHP_IPV6 = "yes";
            PROG_SENDMAIL = "/bin/sendmail";
            WASIXCC_INCLUDE_CPP_SYMBOLS = "yes";
            WASIXCC_WASM_OPT_FLAGS =
              if lib.versionOlder spec.version "8.0"
              then "--pass-arg=max-func-params@32:--fpcast-emu:-O2"
              else if serverSnapshot
              then "--experimental-new-eh:--asyncify:--pass-arg=asyncify-imports@wasix_32v1.proc_snapshot:--pass-arg=asyncify-ignore-indirect:-O2"
              else "--experimental-new-eh:-O2";
            ac_cv_lib_pq_PQchangePassword = "yes";
            ac_cv_lib_pq_PQencryptPasswordConn = "yes";
            ac_cv_lib_pq_PQlibVersion = "yes";
            ac_cv_lib_pq_PQsetErrorContextVisibility = "yes";
            ac_cv_lib_pq_PQsocketPoll = "yes";
            ac_cv_lib_pq_lo_truncate64 = "yes";
            ac_cv_lib_pq_pg_encoding_to_char = "yes";
            php_cv_shm_mmap_anon = "yes";
            php_cv_func_getaddrinfo = "yes";
            php_cv_lib_gd_gdImageCreateFromAvif = "no";
            php_cv_lib_gd_gdImageCreateFromBmp = "yes";
            php_cv_lib_gd_gdImageCreateFromJpeg = "yes";
            php_cv_lib_gd_gdImageCreateFromPng = "yes";
            php_cv_lib_gd_gdImageCreateFromWebp = "yes";
            php_cv_lib_gd_gdImageCreateFromXpm = "no";
          }
          // extensionEnv;

        preConfigure = ''
          patchShebangs buildconf build scripts
          export CURL_LIBS="$(${getDev final.curl}/bin/curl-config --static-libs) -ldl -pthread"
          export LIBS="$LIBS $CURL_LIBS"
          ./buildconf --force
        '';

        postInstall = ''
          install -Dm644 ${phpIni} "$out/lib/php.ini"
        '';

        passthru = {
          extensions = extensionPackages;
          inherit enabledExtensions;
          withExtensions = selector:
            mkPhp webcName spec int64 history ({all, ...}:
              selector {
                enabled = enabledExtensions;
                inherit all;
              });
          wasix = {
            emulatedCheck = {
              ciTags = ["slow-tests"];
              guestInputs = [
                preferredProfilePackages.bash
                preferredProfilePackages.coreutils
              ];
              postRestore = ''
                export NO_INTERACTION=1
                export WASIX_RUN_FLAGS="$WASIX_RUN_FLAGS --volume ${preferredProfilePackages.icu-data}/share/icu/${final.icu.version}:/share/icu/${final.icu.version}"
                patch -p1 < ${phpPatches.testRunner}
                substituteInPlace Makefile \
                  --replace-fail 'TEST_PHP_EXECUTABLE=$(PHP_EXECUTABLE)' \
                  'TEST_PHP_EXECUTABLE=$(PHP_EXECUTABLE).wasm'
              '';
              shards = 8;
              timeout = 3600;
              resultCheck = ''
                ${final.buildPackages.bash}/bin/bash ${./tests/compare-upstream-results.sh} "$_log" ${upstreamBaseline}
              '';
            };
            shipped = true;
            supportedProfiles =
              if lib.versionOlder spec.version "8.0"
              then ["off"]
              else ["exnrefEh"];
          };
          wasmer = {
            owner = "php";
            name = webcName;
            inherit history;
            entrypoint = "php";
            commands = [
              {
                name = "php";
                module = "php";
                wasm = "php.wasm";
                env = {
                  PHPRC = "/etc/php.ini";
                  TMPDIR = ".";
                };
              }
            ];
            autoSelfMount = true;
            fs."/etc/php.ini" = phpIni;
            fs."/etc/ssl" = "${final.cacert}/etc/ssl";
            dependencies = [
              preferredProfilePackages.bash
              preferredProfilePackages.icu-data
              preferredProfilePackages.wasix-sendmail
            ];
          };
        };

        meta = {
          description = "PHP ${spec.version} interpreter for WASIX";
          homepage = "https://www.php.net/";
          license = lib.licenses.php301;
          mainProgram = "php";
        };
      });
  in let
    php32 = lib.mapAttrs (name: spec: mkPhp "php-32" spec false (name != "php85") defaultExtensionSelector) versions;
    php64 = lib.mapAttrs' (name: spec:
      lib.nameValuePair "${name}-int64" (mkPhp "php-64" spec true (name != "php85") defaultExtensionSelector))
    versions;
  in
    php32
    // php64
    // {
      php = php32.php85;
      php-int64 = php64.php85-int64;
    };
}
