# PHP 8.5 — static ZTS libphp for wasix, the dependency phpix embeds. Ported from the old
# pkgs/libraries/php (origin/php85-tailcall): upstream php-src + the php85 patch stack + bundled
# igbinary/imagick. Built through the exnrefEh profile stdenv (wasixcc with WASM_EXCEPTIONS=yes).
#
# Deps go in buildInputs, so the profile stdenv auto-threads -I/-L and pkg-config (PKG_CONFIG_PATH)
# supplies each lib's flags — the old recipe's ~25 hand-fed per-lib *_CFLAGS/*_LIBS were just
# discovery and are gone. Only libs PHP can't find via pkg-config keep explicit flags: iconv (no
# .pc), imagick (config.m4 patched — its .pc lookup name is wrong), pgsql + icu (explicit flags); curl's
# full static link is derived from curl-config in configurePhase (brotli/zstd deps).
#
# Produces `make install-headers install-sapi` (static libphp + headers) for phpix to link via
# passthru.phpExtraLibDirs / phpExtraLinkLibs. exnrefEh-only (passthru.wasix.supportedProfiles).
{
  final,
  prev,
  ...
}: let
  lib = prev.lib;

  versions = import ./versions.nix {inherit (prev) lib fetchFromGitHub;};
  v = versions.php85;

  L = final; # overlay deps, auto-threaded at this profile

  # Deterministic output selection (lib.getLib/getDev pick by the drv's declared outputs, unlike
  # builtins.pathExists which is store-state-dependent at eval).
  includeDir = drv: "${lib.getDev drv}/include";
  libraryDir = drv: "${lib.getLib drv}/lib";

  # libpq splits dev/lib but PHP's --with-pgsql wants one prefix, so synthesize a merged one (+ a
  # stub pg_config). libpq's archives live under its dev output.
  libpqLibraryDir = "${lib.getDev L.libpq}/lib";
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
    L.brotli # curl --with-brotli: libcurl.pc lists -lbrotlidec but its -L is in Libs.private
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
  # phpix links libphp against these (passthru); kept explicit because phpix's link line needs the
  # exact archive names + dirs and can't rederive them from the php build.
  allLibraryDirs = map libraryDir depList ++ [libpqLibraryDir];
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

  # Only the flags PHP can't get from pkg-config + buildInputs. curl/zlib/libxml/sqlite/openssl/png/
  # jpeg/freetype/webp/libzip/sodium/onig are all discovered via pkg-config now.
  configureEnv = {
    # iconv: wasilibc-iconv ships no .pc and its split charset/icrt libs aren't auto-linked.
    ICONV_LIBS = "-liconv -lcharset -licrt";
    # intl/icu: needs an explicit C/C++ std (the -I is redundant with buildInputs but harmless).
    ICU_CFLAGS = "-I${includeDir L.icu} -std=c11";
    ICU_CXXFLAGS = "-I${includeDir L.icu} -std=c++17";
    ICU_LIBS = "-licudata -licui18n -licuio -licuuc";
    # imagick: IM_FIND_IMAGEMAGICK does PKG_CHECK_MODULES([MagickWand]), but the overlay ships the
    # .pc as MagickWand-7.Q16HDRI (the Q16HDRI variant), so that lookup fails — config.m4 is patched
    # (postPatch) to read these explicitly instead.
    IM_IMAGEMAGICK_CFLAGS = "-I${includeDir L.imagemagick}/ImageMagick -DIM_MAGICKWAND_HEADER_STYLE_SEVEN -DMAGICKCORE_QUANTUM_DEPTH=16 -DMAGICKCORE_HDRI_ENABLE=1 -DMAGICKCORE_CHANNEL_MASK_DEPTH=32";
    IM_IMAGEMAGICK_LIBS = "-lMagickWand-7.Q16HDRI -lMagickCore-7.Q16HDRI -ltiff -lz -ldeflate -ljpeg -llzma -lzstd -lpng16 -lwebpmux -lwebpdemux -lwebp -lsharpyuv -lfreetype -lxml2 -lcurl -lssl -lcrypto";
    # pgsql: --with-pgsql=<prefix> (a path) makes PHP's config.m4 skip pkg-config, so it reads these;
    # libpq is the synthetic merged prefix (libpq splits dev/lib).
    PGSQL_CFLAGS = "-I${libpqPrefix}/include";
    PGSQL_LIBS = "-lpq -lpgcommon_shlib -lpgport_shlib -lz -lm";
    PHP_BUILD_SYSTEM = "clang(WASIX+WasmEH)";
    PHP_IPV6 = "yes";
    CFLAGS = "-g -O2 -mtail-call";
    CXXFLAGS = "-g -O2 -mtail-call";
    # pg's static libs at the final link (+ libm); other search dirs come from buildInputs.
    LIBS = "-L${libpqLibraryDir} -lpgcommon_shlib -lpgport_shlib -lm";
    # libpq link-checks can't run on wasm; assert the symbols exist.
    ac_cv_lib_pq_PQlibVersion = "yes";
    ac_cv_lib_pq_PQencryptPasswordConn = "yes";
    ac_cv_lib_pq_PQchangePassword = "yes";
    # NOTE: pg_encoding_to_char is currently missing from the overlay libpq (its libpgcommon lacks the
    # encnames module), so phpix.wasm imports it undefined and won't instantiate until libpq is fixed.
    # php calls it unconditionally (libpq-fe.h decl), so toggling this ac_cv doesn't remove the call.
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
    buildInputs = depList;

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
            patchShebangs ${patchTargets}
    '';

    configurePhase = ''
      runHook preConfigure
      ${exportConfigureEnv}
      # The overlay curl is --with-brotli --with-zstd, so libcurl.a needs their symbols; derive the
      # full static curl link (-L dirs + -l flags for brotli/zstd/openssl/zlib) from curl-config
      # rather than a hand-typed list that goes stale when curl's deps change. (+ php's -ldl -pthread.)
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
