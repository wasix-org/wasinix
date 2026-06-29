# PHP 8.5 — static ZTS libphp for wasix, the dependency phpix embeds. Ported from the old
# pkgs/libraries/php (origin/php85-tailcall): upstream php-src + the php85 patch stack + bundled
# igbinary/imagick. Built through the exnrefEh profile stdenv (which is wasixcc with
# WASM_EXCEPTIONS=yes — the exnref EH the README requires); the old recipe drove wasixcc manually
# via toolchain.commonPreConfigure, but the profile stdenv's shim bakes that env, so we drop it and
# keep only the PHP-specific configure flags / *_CFLAGS / *_LIBS.
#
# This produces `make install-headers install-sapi` (static libphp + headers), NOT a runnable php —
# phpix links it via passthru.phpExtraLibDirs / phpExtraLinkLibs. exnrefEh-only
# (passthru.wasix.supportedProfiles).
{
  final,
  prev,
  ...
}: let
  lib = prev.lib;

  versions = import ./versions.nix {inherit (prev) lib fetchFromGitHub;};
  v = versions.php85;

  L = final; # overlay deps, auto-threaded at this profile

  # Deterministic output selection. The old recipe used builtins.pathExists, which is
  # store-state-dependent at eval (false for unbuilt deps -> wrong dir); lib.getLib/getDev pick by
  # the drv's declared outputs instead.
  includeDir = drv: "${lib.getDev drv}/include";
  libraryDir = drv: "${lib.getLib drv}/lib";
  pkgConfigDir = drv: "${lib.getDev drv}/lib/pkgconfig";

  # libpq ships its archives + .pc under its dev output.
  libpqLibraryDir = "${lib.getDev L.libpq}/lib";
  libpqPkgConfigDir = "${lib.getDev L.libpq}/lib/pkgconfig";
  # PHP's --with-pgsql wants one prefix; libpq splits dev/lib, so synthesize a merged prefix
  # (+ a stub pg_config) from the libpq outputs.
  libpqPrefix = final.buildPackages.stdenvNoCC.mkDerivation {
    name = "php85-libpq-prefix";
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p "$out/include" "$out/lib" "$out/bin"
      cp -a ${lib.getDev L.libpq}/include/. "$out/include/"
      cp -a ${libpqLibraryDir}/. "$out/lib/"
      cat > "$out/bin/pg_config" <<EOF
      #!${final.buildPackages.bash}/bin/sh
      case "\$1" in
        --includedir) echo "$out/include" ;;
        --libdir) echo "$out/lib" ;;
        *) echo "unsupported pg_config argument: \$1" >&2; exit 1 ;;
      esac
      EOF
      chmod +x "$out/bin/pg_config"
    '';
  };

  depList = [
    L.curl
    # brotli: the overlay curl is built --with-brotli, so libcurl.pc lists -lbrotlidec/-lbrotlicommon
    # but their -L dir lives in Libs.private (not on PHP's non-static pkg-config line). Include
    # brotli here so its -L reaches the link search path (the old recipe predates curl's brotli dep).
    L.brotli
    L.zlib
    L.xz
    L.libxml2
    L.sqlite
    L.openssl
    L.libiconv
    L.icu
    L.libpng
    L.libjpeg
    L.freetype
    L.libwebp
    L.libzip
    L.libsodium
    L.oniguruma
    L.libdeflate
    L.zstd
    L.libtiff
    L.imagemagick
  ];
  allLibraryDirs = map libraryDir depList ++ [libpqLibraryDir];
  pkgConfigPath = lib.concatStringsSep ":" (map pkgConfigDir depList ++ [libpqPkgConfigDir]);
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

  # PHP-specific configure env. Dropped vs the old recipe: CC/CXX/AR/NM/RANLIB (the profile stdenv
  # provides them) and WASIXCC_WASM_EXCEPTIONS (the exnrefEh stdenv sets it to yes).
  configureEnv = {
    CURL_CFLAGS = "-I${includeDir L.curl}";
    CURL_LIBS = "-lcurl -lssl -lcrypto -ldl -pthread -lz";
    ZLIB_CFLAGS = "-I${includeDir L.zlib}";
    ZLIB_LIBS = "-lz";
    LIBXML_CFLAGS = "-I${includeDir L.libxml2}/libxml2";
    LIBXML_LIBS = "-lxml2 -llzma -lz";
    SQLITE_CFLAGS = "-I${includeDir L.sqlite}";
    SQLITE_LIBS = "-lsqlite3";
    OPENSSL_CFLAGS = "-I${includeDir L.openssl}";
    OPENSSL_LIBS = "-lssl -lcrypto";
    ICONV_CFLAGS = "-I${includeDir L.libiconv}";
    ICONV_LIBS = "-liconv -lcharset -licrt";
    ICU_CFLAGS = "-I${includeDir L.icu} -std=c11";
    ICU_CXXFLAGS = "-I${includeDir L.icu} -std=c++17";
    ICU_LIBS = "-licudata -licui18n -licuio -licuuc";
    PNG_CFLAGS = "-I${includeDir L.libpng} -I${includeDir L.libpng}/libpng16";
    PNG_LIBS = "-lpng16 -lz";
    JPEG_CFLAGS = "-I${includeDir L.libjpeg}";
    JPEG_LIBS = "-ljpeg";
    FREETYPE2_CFLAGS = "-I${includeDir L.freetype} -I${includeDir L.freetype}/freetype2";
    FREETYPE2_LIBS = "-lfreetype -lpng16 -lz";
    WEBP_CFLAGS = "-I${includeDir L.libwebp}";
    WEBP_LIBS = "-lwebp -lsharpyuv";
    LIBZIP_CFLAGS = "-I${includeDir L.libzip}";
    LIBZIP_LIBS = "-lzip -llzma -lz";
    LIBSODIUM_CFLAGS = "-I${includeDir L.libsodium}";
    LIBSODIUM_LIBS = "-lsodium";
    ONIG_CFLAGS = "-I${includeDir L.oniguruma}";
    ONIG_LIBS = "-lonig";
    IM_IMAGEMAGICK_CFLAGS = "-I${includeDir L.imagemagick}/ImageMagick -DIM_MAGICKWAND_HEADER_STYLE_SEVEN -DMAGICKCORE_QUANTUM_DEPTH=16 -DMAGICKCORE_HDRI_ENABLE=1 -DMAGICKCORE_CHANNEL_MASK_DEPTH=32";
    IM_IMAGEMAGICK_LIBS = "-lMagickWand-7.Q16HDRI -lMagickCore-7.Q16HDRI -ltiff -lz -ldeflate -ljpeg -llzma -lzstd -lpng16 -lwebpmux -lwebpdemux -lwebp -lsharpyuv -lfreetype -lxml2 -lcurl -lssl -lcrypto";
    PGSQL_CFLAGS = "-I${libpqPrefix}/include";
    PGSQL_LIBS = "-lpq -lpgcommon_shlib -lpgport_shlib -lz -lm";
    PHP_BUILD_SYSTEM = "clang(WASIX+WasmEH)";
    PHP_EXTRA_INCLUDES = "";
    PHP_IPV6 = "yes";
    PKG_CONFIG_PATH = pkgConfigPath;
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
    WASIXCC_RUN_WASM_OPT = "no";
    PROG_SENDMAIL = "/usr/bin/sendmail";
  };
  exportConfigureEnv = lib.concatStringsSep "\n" (lib.mapAttrsToList (n: val: "export ${n}=${lib.escapeShellArg val}") configureEnv);

  bundledExtensions = v.bundledExtensions;
  bundledNames = builtins.attrNames bundledExtensions;
  copyBundledExtensions =
    lib.concatMapStringsSep "\n" (name: let
      ext = bundledExtensions.${name};
      extPatches = lib.concatMapStringsSep "\n" (p: "patch -p1 < ${lib.escapeShellArg "${p}"}") (ext.patches or []);
    in ''
      rm -rf "ext/${name}"
      mkdir -p "ext/${name}"
      cp -R --no-preserve=mode,ownership ${ext.src}/. "ext/${name}"
      chmod -R u+w "ext/${name}"
      ${extPatches}
    '')
    bundledNames;
  patchTargets = lib.concatStringsSep " " (["buildconf" "build" "scripts"] ++ map (n: "ext/${n}") bundledNames);
in
  final.stdenv.mkDerivation {
    inherit (v) pname version src patches;

    nativeBuildInputs = with final.buildPackages; [
      autoconf
      bison
      re2c
      pkg-config
      gnumake
      perl
      python3
      coreutils
    ];

    enableParallelBuilding = true;

    postPatch = ''
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

    configurePhase = ''
      runHook preConfigure
      ${exportConfigureEnv}
      # The overlay curl is --with-brotli --with-zstd, so libcurl.a needs their symbols; derive the
      # full static curl link (-L dirs + -l flags for brotli/zstd/openssl/zlib) from curl-config
      # rather than the recipe's static CURL_LIBS, which predates curl's brotli/zstd deps. (+ php's
      # -ldl -pthread, which curl-config doesn't emit.)
      export CURL_LIBS="$(${lib.getDev L.curl}/bin/curl-config --static-libs) -ldl -pthread"
      installPrefix="$PWD/install"
      ./buildconf --force
      ./configure ${lib.escapeShellArgs (v.configureFlags ++ ["--with-pgsql=${libpqPrefix}" "--with-pdo-pgsql=${libpqPrefix}"])} --prefix="$installPrefix"
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

    passthru = {
      phpExtraLibDirs = allLibraryDirs;
      inherit phpExtraLinkLibs bundledExtensions;
      wasix.supportedProfiles = ["exnrefEh"];
    };

    meta =
      (v.meta or {})
      // {
        description = "Static PHP 8.5 WASIX ZTS libphp build";
      };
  }
