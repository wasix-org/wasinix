{
  lib,
  stdenvNoCC,
  autoconf,
  bison,
  re2c,
  pkg-config,
  gnumake,
  perl,
  python3,
  coreutils,
  patch,
  toolchain,
}:
{
  pname,
  version,
  src,
  phpLibraries,
  patches ? [ ],
  bundledExtensions ? { },
  configureFlags,
  meta ? { },
  passthru ? { },
}:
let
  outputOrSelf =
    output: drv:
    if builtins.elem output (drv.outputs or [ "out" ]) then builtins.getAttr output drv else drv;

  outOutput = drv: outputOrSelf "out" drv;
  devOutput = drv: outputOrSelf "dev" drv;
  libOutput = drv:
    if builtins.elem "lib" (drv.outputs or [ "out" ]) then
      drv.lib
    else if builtins.pathExists "${outOutput drv}/lib" then
      outOutput drv
    else
      devOutput drv;
  includeDir = drv: "${devOutput drv}/include";
  libraryDir = drv: "${libOutput drv}/lib";
  pkgConfigDir = drv:
    let
      devPkgConfigDir = "${devOutput drv}/lib/pkgconfig";
    in
    if builtins.pathExists devPkgConfigDir then devPkgConfigDir else "${libOutput drv}/lib/pkgconfig";
  libpqLibraryDir = "${devOutput phpLibraries.libpq}/lib";
  libpqPkgConfigDir = "${devOutput phpLibraries.libpq}/lib/pkgconfig";
  libpqPrefix = stdenvNoCC.mkDerivation {
    name = "${pname}-libpq-prefix";
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p "$out/include" "$out/lib" "$out/bin"
      cp -a ${devOutput phpLibraries.libpq}/include/. "$out/include/"
      cp -a ${libpqLibraryDir}/. "$out/lib/"

      cat > "$out/bin/pg_config" <<EOF
      #!${stdenvNoCC.shell}
      case "\$1" in
        --includedir)
          echo "$out/include"
          ;;
        --libdir)
          echo "$out/lib"
          ;;
        *)
          echo "unsupported pg_config argument: \$1" >&2
          exit 1
          ;;
      esac
      EOF
      chmod +x "$out/bin/pg_config"
    '';
  };

  allLibraryDirs = map libraryDir [
    phpLibraries.curl
    phpLibraries.zlib
    phpLibraries.xz
    phpLibraries.libxml2
    phpLibraries.sqlite
    phpLibraries.openssl
    phpLibraries.libiconv
    phpLibraries.icu
    phpLibraries.libpng
    phpLibraries.libjpeg
    phpLibraries.freetype
    phpLibraries.libwebp
    phpLibraries.libzip
    phpLibraries.libsodium
    phpLibraries.oniguruma
    phpLibraries.libdeflate
    phpLibraries.zstd
    phpLibraries.libtiff
    phpLibraries.imagemagick
  ] ++ [ libpqLibraryDir ];

  pkgConfigPath = lib.concatStringsSep ":" (map pkgConfigDir [
    phpLibraries.curl
    phpLibraries.zlib
    phpLibraries.xz
    phpLibraries.libxml2
    phpLibraries.sqlite
    phpLibraries.openssl
    phpLibraries.libiconv
    phpLibraries.icu
    phpLibraries.libpng
    phpLibraries.libjpeg
    phpLibraries.freetype
    phpLibraries.libwebp
    phpLibraries.libzip
    phpLibraries.libsodium
    phpLibraries.oniguruma
    phpLibraries.libdeflate
    phpLibraries.zstd
    phpLibraries.libtiff
    phpLibraries.imagemagick
  ] ++ [ libpqPkgConfigDir ]);

  librarySearchFlags = lib.concatMapStringsSep " " (dir: "-L${dir}") allLibraryDirs;
  phpExtraLinkLibs = [
    "MagickCore-7.Q16HDRI"
    "MagickWand-7.Q16HDRI"
    "crypto"
    "curl"
    "freetype"
    "icudata"
    "icui18n"
    "icuio"
    "icuuc"
    "jpeg"
    "lzma"
    "onig"
    "pgcommon_shlib"
    "pgport_shlib"
    "png16"
    "pq"
    "sharpyuv"
    "sodium"
    "sqlite3"
    "ssl"
    "deflate"
    "tiff"
    "webpmux"
    "webpdemux"
    "webp"
    "xml2"
    "z"
    "zstd"
    "zip"
  ];
in
stdenvNoCC.mkDerivation {
  inherit pname version src patches;

  nativeBuildInputs = [
    toolchain.wasixcc
    autoconf
    bison
    re2c
    pkg-config
    gnumake
    perl
    python3
    coreutils
    patch
  ];

  enableParallelBuilding = true;

  postPatch =
    let
      bundledExtensionNames = builtins.attrNames bundledExtensions;
      copyBundledExtensions = lib.concatMapStringsSep "\n" (name:
        let
          extension = bundledExtensions.${name};
          extensionPatches = extension.patches or [ ];
          applyExtensionPatches = lib.concatMapStringsSep "\n" (patchFile:
            "patch -p1 < ${lib.escapeShellArg "${patchFile}"}"
          ) extensionPatches;
        in
        ''
          rm -rf "ext/${name}"
          mkdir -p "ext/${name}"
          cp -R --no-preserve=mode,ownership ${extension.src}/. "ext/${name}"
          chmod -R u+w "ext/${name}"
          ${applyExtensionPatches}
        ''
      ) bundledExtensionNames;
      patchTargets = lib.concatStringsSep " " ([ "buildconf" "build" "scripts" ] ++ map (name: "ext/${name}") bundledExtensionNames);
    in
    ''
      ${copyBundledExtensions}
      substituteInPlace ext/imagick/config.m4 \
        --replace-fail 'IM_FIND_IMAGEMAGICK([6.5.3], [$PHP_IMAGICK])' '# WASIX passes ImageMagick paths explicitly via IM_IMAGEMAGICK_{CFLAGS,LIBS}.
# IM_FIND_IMAGEMAGICK([6.5.3], [$PHP_IMAGICK])'
      substituteInPlace ext/imagick/php_imagick.h \
        --replace-fail '#define PHP_IMAGICK_VERSION    "@PACKAGE_VERSION@"' '#define PHP_IMAGICK_VERSION    "3.8.1"'
      substituteInPlace ext/imagick/imagick.c \
        --replace-fail 'ext/standard/php_smart_string.h' 'Zend/zend_smart_string.h'
      substituteInPlace ext/igbinary/src/php7/php_igbinary.h \
        --replace-fail 'ext/standard/php_smart_string.h' 'Zend/zend_smart_string.h'
      perl -0pi -e 's|AS_CASE\(\[\$4\], \[yes\], \[pgsql_dir=""\], \[pgsql_dir=\$4\]\)\nAS_VAR_IF\(\[pgsql_dir\],,\n  \[PKG_CHECK_MODULES\(\[PGSQL\], \[libpq >= 10\.0\],\n    \[found_pgsql=yes\],\n    \[found_pgsql=no\]\)\]\)|AS_CASE([\$4], [yes], [pgsql_dir=""], [pgsql_dir=\$4])\nAS_IF([test -n "\\$PGSQL_CFLAGS" && test -n "\\$PGSQL_LIBS"],\n  [found_pgsql=yes])\nAS_IF([test "\\$found_pgsql" = "no"], [\n  AS_VAR_IF([pgsql_dir],,\n    [PKG_CHECK_MODULES([PGSQL], [libpq >= 10.0],\n      [found_pgsql=yes],\n      [found_pgsql=no])])\n])|s' build/php.m4
      patchShebangs ${patchTargets}
    '';

  configurePhase =
    let
      configureEnv = {
        CURL_CFLAGS = "-I${includeDir phpLibraries.curl}";
        CURL_LIBS = "-lcurl -lssl -lcrypto -ldl -pthread -lz";
        ZLIB_CFLAGS = "-I${includeDir phpLibraries.zlib}";
        ZLIB_LIBS = "-lz";
        LIBXML_CFLAGS = "-I${includeDir phpLibraries.libxml2}/libxml2";
        LIBXML_LIBS = "-lxml2 -llzma -lz";
        SQLITE_CFLAGS = "-I${includeDir phpLibraries.sqlite}";
        SQLITE_LIBS = "-lsqlite3";
        OPENSSL_CFLAGS = "-I${includeDir phpLibraries.openssl}";
        OPENSSL_LIBS = "-lssl -lcrypto";
        ICONV_CFLAGS = "-I${includeDir phpLibraries.libiconv}";
        ICONV_LIBS = "-liconv -lcharset -licrt";
        ICU_CFLAGS = "-I${includeDir phpLibraries.icu} -std=c11";
        ICU_CXXFLAGS = "-I${includeDir phpLibraries.icu} -std=c++17";
        ICU_LIBS = "-licudata -licui18n -licuio -licuuc";
        PNG_CFLAGS = "-I${includeDir phpLibraries.libpng} -I${includeDir phpLibraries.libpng}/libpng16";
        PNG_LIBS = "-lpng16 -lz";
        JPEG_CFLAGS = "-I${includeDir phpLibraries.libjpeg}";
        JPEG_LIBS = "-ljpeg";
        FREETYPE2_CFLAGS = "-I${includeDir phpLibraries.freetype} -I${includeDir phpLibraries.freetype}/freetype2";
        FREETYPE2_LIBS = "-lfreetype -lpng16 -lz";
        WEBP_CFLAGS = "-I${includeDir phpLibraries.libwebp}";
        WEBP_LIBS = "-lwebp -lsharpyuv";
        LIBZIP_CFLAGS = "-I${includeDir phpLibraries.libzip}";
        LIBZIP_LIBS = "-lzip -llzma -lz";
        LIBSODIUM_CFLAGS = "-I${includeDir phpLibraries.libsodium}";
        LIBSODIUM_LIBS = "-lsodium";
        ONIG_CFLAGS = "-I${includeDir phpLibraries.oniguruma}";
        ONIG_LIBS = "-lonig";
        IM_IMAGEMAGICK_CFLAGS = "-I${includeDir phpLibraries.imagemagick}/ImageMagick -DIM_MAGICKWAND_HEADER_STYLE_SEVEN -DMAGICKCORE_QUANTUM_DEPTH=16 -DMAGICKCORE_HDRI_ENABLE=1 -DMAGICKCORE_CHANNEL_MASK_DEPTH=32";
        IM_IMAGEMAGICK_LIBS = "-lMagickWand-7.Q16HDRI -lMagickCore-7.Q16HDRI -ltiff -lz -ldeflate -ljpeg -llzma -lzstd -lpng16 -lwebpmux -lwebpdemux -lwebp -lsharpyuv -lfreetype -lxml2 -lcurl -lssl -lcrypto";
        PGSQL_CFLAGS = "-I${libpqPrefix}/include";
        PGSQL_LIBS = "-lpq -lpgcommon_shlib -lpgport_shlib -lz -lm";
        PHP_BUILD_SYSTEM = "clang(WASIX+WasmEH)";
        PHP_EXTRA_INCLUDES = "";
        PHP_IPV6 = "yes";
        PKG_CONFIG_PATH = pkgConfigPath;
        RANLIB = "wasixranlib";
        AR = "wasixar";
        NM = "wasixnm";
        CC = "wasixcc";
        CXX = "wasixcc++";
        CFLAGS = "-g -O2 -mtail-call";
        CXXFLAGS = "-g -O2 -mtail-call";
        LIBS = "${librarySearchFlags} -lpgcommon_shlib -lpgport_shlib -lm --no-wasm-opt";
        ac_cv_lib_pq_PQlibVersion = "yes";
        ac_cv_lib_pq_PQencryptPasswordConn = "yes";
        ac_cv_lib_pq_PQchangePassword = "yes";
        ac_cv_lib_pq_pg_encoding_to_char = "yes";
        ac_cv_lib_pq_lo_truncate64 = "yes";
        ac_cv_lib_pq_PQsocketPoll = "yes";
        ac_cv_lib_pq_PQsetErrorContextVisibility = "yes";
        WASIXCC_INCLUDE_CPP_SYMBOLS = "yes";
        WASIXCC_WASM_EXCEPTIONS = "yes";
        PROG_SENDMAIL = "/usr/bin/sendmail";
      };
      exportConfigureEnv = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value:
        "export ${name}=${lib.escapeShellArg value}"
      ) configureEnv);
    in
    ''
      runHook preConfigure

      ${toolchain.commonPreConfigure}
      ${exportConfigureEnv}

      installPrefix="$PWD/install"
      ./buildconf --force
      ./configure ${lib.escapeShellArgs (
        configureFlags
        ++ [
          "--with-pgsql=${libpqPrefix}"
          "--with-pdo-pgsql=${libpqPrefix}"
        ]
      )} --prefix="$installPrefix"

      runHook postConfigure
    '';

  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-1} install-headers install-sapi
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a install/. "$out/"
    runHook postInstall
  '';

  passthru = passthru // {
    inherit phpLibraries bundledExtensions;
    phpExtraLibDirs = allLibraryDirs;
    inherit phpExtraLinkLibs;
  };

  meta = {
    description = "Static WASIX libphp build";
    homepage = "https://github.com/php/php-src";
  } // meta;
}
