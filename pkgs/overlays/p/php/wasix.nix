{
  extendPackage,
  packages,
  pkgs,
  profileOf,
  wasmRename,
}: let
  versions = import ./versions.nix;
  final = packages.sameProfile;
  inherit (packages) preferred;
  inherit (pkgs) lib;
  inherit (lib) getDev getLib;
  libc = packages.native.wasix-sysroot.profiles.${profileOf final.stdenv.hostPlatform}.libc;

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

  wasixConfigureFlags = spec: enabledExtensions: libphpBuild:
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
      (
        if libphpBuild
        then "--without-readline"
        else "--with-readline=${getDev final.readline}"
      )
      "--with-sodium"
      "--with-tidy=${final.html-tidy}"
      "--with-valgrind=no"
      "--with-zip"
      "--with-zlib"
    ]
    ++ map (extension: extension.configureFlag) enabledExtensions
    ++ lib.optionals libphpBuild [
      "--enable-embed=static"
      "--enable-zts"
    ]
    ++ lib.optional (lib.versionOlder spec.version "8.5") "--enable-opcache"
    ++ lib.optional (lib.versionAtLeast spec.version "8.0") "--disable-opcache-jit"
    ++ lib.optional (lib.versionAtLeast spec.version "8.1") "--enable-fiber-asm";

  defaultExtensionSelector = {enabled, ...}: enabled;

  mkPhp = webcName: spec: int64: history: extensionSelector:
    mkPhpVariant {
      inherit extensionSelector history int64 spec webcName;
      libphpBuild = false;
    };

  mkPhpVariant = {
    webcName,
    spec,
    int64,
    history,
    extensionSelector,
    libphpBuild,
  }: let
    serverSnapshot = lib.versionAtLeast spec.version "8.1";
    src = final.fetchFromGitHub {
      owner = "php";
      repo = "php-src";
      inherit (spec) rev hash;
    };
    phpPatches = import ./patches {
      inherit lib int64 serverSnapshot;
      inherit (spec) version;
    };
    basePhp = final.callPackage "${pkgs.path}/pkgs/development/interpreters/php/generic.nix" {
      inherit (spec) version;
      phpSrc = src;
      cgiSupport = false;
      fpmSupport = false;
      pearSupport = false;
      phpdbgSupport = false;
      staticSupport = true;
      embedSupport = libphpBuild;
      ztsSupport = libphpBuild;
      argon2Support = false;
      systemdSupport = false;
      valgrindSupport = false;
      phpAttrsOverrides = _: previous: {
        outputs = ["out"];
        separateDebugInfo = false;
        doCheck = true;
        checkTarget = "test";
        wasixCheckPrebuild = ''make -j"''${NIX_BUILD_CORES:-1}" all'';
        meta = previous.meta // {outputsToInstall = ["out"];};
      };
    };
    nixpkgsPhpPackages = final.callPackage "${pkgs.path}/pkgs/top-level/php-packages.nix" {
      phpPackage = basePhp // {unwrapped = basePhp;};
    };
    nixpkgsExtensions = nixpkgsPhpPackages.extensions;
    extensionPackages = import ./extensions.nix {
      inherit final lib nixpkgsExtensions;
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
    staticLinkDirs = map (input: "-L${getLib input}/lib") (baseBuildInputs ++ extensionBuildInputs);
    staticLinkLibs =
      [
        "-lc++"
        "-lc++abi"
        "-lunwind"
      ]
      ++ lib.concatMap (extension: extension.staticLinkLibs or []) enabledExtensions;
    upstreamBaseline =
      ./tests/upstream-baselines
      + "/php${lib.versions.major spec.version}${lib.versions.minor spec.version}${lib.optionalString int64 "-int64"}.txt";
    phpIni = final.buildPackages.runCommand "php-${spec.version}.ini" {} ''
      install -m644 ${src}/php.ini-production "$out"
      printf '%s\n' \
        'curl.cainfo = /etc/ssl/certs/ca-bundle.crt' \
        'openssl.cafile = /etc/ssl/certs/ca-bundle.crt' \
        'openssl.capath = /etc/ssl/certs' \
        'opcache.enable_cli = 1' \
        >> "$out"
    '';
  in
    wasmRename {wasmName = "php";} (extendPackage basePhp {
      patches = phpPatches.source;
      nativeBuildInputs = [final.disableWasmOptInConfigureHook];
      buildInputs = _: baseBuildInputs ++ extensionBuildInputs;
      configureFlags = _: wasixConfigureFlags spec enabledExtensions libphpBuild;

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

      preConfigure = _: ''
        patchShebangs buildconf build scripts
        export CURL_LIBS="$(${getDev final.curl}/bin/curl-config --static-libs) -ldl -pthread"
        export LIBS="$LIBS $CURL_LIBS"
        ./buildconf --force
      '';

      preInstall = _: ":";

      installPhase = old:
        if libphpBuild
        then ''
          runHook preInstall
          make install-headers install-sapi
          install -Dm755 scripts/php-config "$out/bin/php-config"
          substituteInPlace "$out/bin/php-config" \
            --replace-fail \
            'extension_dir=' \
            $'ldflags="$ldflags ${lib.concatStringsSep " " staticLinkDirs}"\nlibs="$libs ${lib.concatStringsSep " " staticLinkLibs}"\nextension_dir='
          runHook postInstall
        ''
        else old;

      postInstall = lib.optionalString (!libphpBuild) ''
        install -Dm644 ${phpIni} "$out/lib/php.ini"
      '';
      postFixup = _: "";

      passthru = old:
        removeAttrs old ["buildEnv" "updateScript"]
        // {
          extensions = extensionPackages;
          inherit enabledExtensions;
          withExtensions = selector:
            mkPhpVariant {
              inherit history int64 libphpBuild spec webcName;
              extensionSelector = {all, ...}:
                selector {
                  enabled = enabledExtensions;
                  inherit all;
                };
            };
          wasix.supportedProfiles =
            if lib.versionOlder spec.version "8.0"
            then ["off"]
            else ["exnrefEh"];
        }
        // lib.optionalAttrs (!libphpBuild && lib.versionAtLeast spec.version "8.1") {
          libphp = mkPhpVariant {
            inherit extensionSelector history int64 spec webcName;
            libphpBuild = true;
          };
        }
        // lib.optionalAttrs (!libphpBuild) {
          wasinix = {
            aliases = lib.optional (!history) (
              if int64
              then "php-int64"
              else "php"
            );
            shipped = true;
            checks.captured = {
              tags = ["slow-tests"];
              guestInputs = [
                preferred.bash
                preferred.coreutils
              ];
              postRestore = ''
                export NO_INTERACTION=1
                export TEST_PHP_ARGS="--set-timeout 300"
                    export WASIX_RUN_FLAGS="$WASIX_RUN_FLAGS --volume ${preferred.icu-data}/share/icu/${final.icu.version}:/share/icu/${final.icu.version}"
                patch -p1 < ${phpPatches.testRunner}
                substituteInPlace Makefile \
                  --replace-fail 'TEST_PHP_EXECUTABLE=$(PHP_EXECUTABLE)' \
                  'TEST_PHP_EXECUTABLE=$(PHP_EXECUTABLE).wasm'
              '';
              shards = 8;
              timeout = 7200;
              resultCheck = ''
                ${final.buildPackages.bash}/bin/bash ${./tests/compare-upstream-results.sh} "$_log" ${upstreamBaseline}
              '';
            };
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
                global = !int64;
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
              preferred.bash
              preferred.icu-data
              preferred.wasix-sendmail
            ];
          };
        };

      meta = {
        description =
          if libphpBuild
          then "PHP ${spec.version} ZTS embed SAPI for WASIX"
          else "PHP ${spec.version} interpreter for WASIX";
      };
    });
  php32 = lib.mapAttrs (name: spec: mkPhp "php-32" spec false (name != "php85") defaultExtensionSelector) versions;
  php64 = lib.mapAttrs' (name: spec:
    lib.nameValuePair "${name}-int64" (mkPhp "php-64" spec true (name != "php85") defaultExtensionSelector))
  versions;
in
  php32
  // php64
  // {
    php = php32.php85.overrideAttrs (old: {
      passthru = (old.passthru or {}) // {wasinix = ((old.passthru or {}).wasinix or {}) // {catalog = false;};};
    });
    php-int64 = php64.php85-int64.overrideAttrs (old: {
      passthru = (old.passthru or {}) // {wasinix = ((old.passthru or {}).wasinix or {}) // {catalog = false;};};
    });
  }
