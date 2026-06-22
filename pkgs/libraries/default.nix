{
  nixpkgs,
  pkgs,
  pkgsCross,
  toolchain,
  includePhp ? true,
}: let
  inherit (pkgs) lib;
  # off-EH <setjmp.h> gates sigsetjmp out; packages sharing bash's configure
  # macros must pick plain setjmp.
  offMode = (toolchain.wasmExceptions or "yes") == "no";
  mkUpstreamLibrary = pkgs.callPackage ./mk-upstream-library.nix {
    inherit toolchain;
  };
  baseLibraries = lib.fix (self: {
    zlib = mkUpstreamLibrary {
      package = pkgsCross.zlib;
      doCheck = false;
      overrideAttrs = old: {
        buildPhase = ''
          runHook preBuild
          make -j''${NIX_BUILD_CORES:-1} libz.a
          runHook postBuild
        '';
      };
    };

    zlib-ng = mkUpstreamLibrary {
      package = pkgsCross.zlib-ng.override {
        gtest = null;
      };
      doCheck = false;
    };

    xz = mkUpstreamLibrary {
      package = pkgsCross.xz;
      doCheck = false;
    };

    zstd = mkUpstreamLibrary {
      package = pkgsCross.zstd.override {
        bashNonInteractive = pkgs.bashNonInteractive;
        gnugrep = pkgs.gnugrep;
      };
      doCheck = false;
    };

    libxml2 = mkUpstreamLibrary {
      package = pkgsCross.libxml2.override {
        enableHttp = false;
        pythonSupport = false;
        icuSupport = false;
      };
      doCheck = false;
      configureFlags = [
        "--with-modules=no"
      ];
    };

    sqlite = mkUpstreamLibrary {
      package = pkgsCross.sqlite.override {
        zlib = self.zlib;
      };
      doCheck = false;
    };

    openssl = pkgs.callPackage ./openssl.nix {
      inherit pkgsCross toolchain;
    };

    # WASIX already provides iconv in the sysroot/libc surface, so we keep the
    # nixpkgs shim package here rather than forcing GNU libiconv through WASI.
    libiconv = pkgsCross.libiconv;

    icu = mkUpstreamLibrary {
      package = pkgsCross.icu;
      doCheck = false;
      configureFlags = [
        "--with-data-packaging=archive"
        "--disable-extras"
        "--disable-samples"
        "--disable-tests"
        "--disable-tools"
      ];
      postPatch = ''
        patch -p1 < ${./patches/icu-no-tzname-on-unknown.patch}
      '';
      preConfigure = ''
        cp config/mh-linux config/mh-unknown
      '';
    };

    libpng = mkUpstreamLibrary {
      package = pkgsCross.libpng.override {
        zlib = self.zlib;
      };
      doCheck = false;
      extraBuildInputs = [self.zlib];
      env = {
        CPPFLAGS = "-I${lib.getDev self.zlib}/include";
        LDFLAGS = "-L${lib.getLib self.zlib}/lib";
      };
    };

    libjpeg = mkUpstreamLibrary {
      package = pkgsCross.libjpeg;
      doCheck = false;
      postInstall = ''
        mkdir -p "$man/share/man"
      '';
    };

    libdeflate = mkUpstreamLibrary {
      package = pkgsCross.libdeflate.override {
        zlib = self.zlib;
      };
      doCheck = false;
    };

    potrace = mkUpstreamLibrary {
      package = pkgsCross.potrace.override {
        zlib = self.zlib;
      };
      doCheck = false;
      overrideAttrs = old: {
        outputs = [
          "out"
          "dev"
        ];
        buildPhase = ''
          runHook preBuild
          make -C src -j''${NIX_BUILD_CORES:-1} libpotrace.la
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall

          mkdir -p "$out/lib" "$dev/include"
          cp src/.libs/libpotrace.a "$out/lib/"
          cp src/potracelib.h "$dev/include/"

          runHook postInstall
        '';
        env =
          (old.env or {})
          // {
            CPPFLAGS = "-I${lib.getDev self.zlib}/include";
            LDFLAGS = "-L${lib.getLib self.zlib}/lib";
          };
      };
    };

    freetype = mkUpstreamLibrary {
      package = pkgsCross.freetype.override {
        zlib = self.zlib;
        libpng = self.libpng;
      };
      doCheck = false;
      overrideAttrs = old: {
        nativeBuildInputs =
          [toolchain.wasixcc]
          ++ lib.filter (
            input: let
              name = input.pname or input.name or "";
            in
              name != "make-shell-wrapper-hook"
          ) (old.nativeBuildInputs or []);
        propagatedBuildInputs = [
          self.zlib
          self.libpng
        ];
        postInstall = "";
      };
    };

    libzip = mkUpstreamLibrary {
      package = pkgsCross.libzip.override {
        zlib = self.zlib;
        withLZMA = true;
        xz = self.xz;
      };
      doCheck = false;
    };

    libsodium = mkUpstreamLibrary {
      package = pkgsCross.libsodium;
      doCheck = false;
    };

    curl = mkUpstreamLibrary {
      package = pkgsCross.curlMinimal.override {
        brotliSupport = false;
        c-aresSupport = false;
        gssSupport = false;
        http2Support = false;
        http3Support = false;
        websocketSupport = false;
        idnSupport = false;
        ldapSupport = false;
        opensslSupport = true;
        openssl = self.openssl;
        pslSupport = false;
        rtmpSupport = false;
        rustlsSupport = false;
        scpSupport = false;
        zlibSupport = true;
        zlib = self.zlib;
        zstdSupport = false;
      };
      doCheck = false;
    };

    oniguruma = mkUpstreamLibrary {
      package = pkgsCross.oniguruma;
      doCheck = false;
    };

    libpq = mkUpstreamLibrary {
      package = pkgsCross.callPackage "${nixpkgs}/pkgs/servers/sql/postgresql/libpq.nix" {
        curlSupport = false;
        gssSupport = false;
        nlsSupport = false;
        openssl = self.zlib;
        tzdata = pkgs.tzdata;
        zlib = self.zlib;
      };
      doCheck = false;
      overrideAttrs = old: {
        installPhase = lib.replaceStrings ["rm -rfv $dev/lib/*_shlib.a"] [""] (old.installPhase or "");
        buildInputs = lib.filter (
          input: let
            name = input.pname or input.name or "";
          in
            !lib.elem name [
              "curl"
              "gettext"
              "libkrb5"
              "openssl"
            ]
        ) (old.buildInputs or []);
        nativeBuildInputs =
          lib.filter (
            input: let
              name = input.pname or input.name or "";
            in
              name != "make-shell-wrapper-hook"
          ) (
            [toolchain.wasixcc] ++ (old.nativeBuildInputs or [])
          );
        configureFlags =
          (lib.filter (
            flag:
              flag != "--with-openssl"
          ) (old.configureFlags or []))
          ++ [
            "--with-template=linux"
          ];
        env =
          (old.env or {})
          // {
            CPPFLAGS = "-I${lib.getDev self.zlib}/include";
            LDFLAGS = "-L${lib.getLib self.zlib}/lib";
          };
        postInstall =
          (lib.replaceStrings ["rm -rfv $dev/lib/*_shlib.a"] [""] (old.postInstall or ""))
          + "\n"
          + ''
            pc="$dev/lib/pkgconfig/libpq.pc"
            if [ -f "$pc" ]; then
              libs="$(sed -n 's/^Libs: //p' "$pc")"
              libs_private="$(sed -n 's/^Libs.private: //p' "$pc")"
              libs_private="$(printf '%s' "$libs_private" | sed 's/-lpgcommon\\b/-lpgcommon_shlib/g; s/-lpgport\\b/-lpgport_shlib/g')"
              sed -i "s|^Libs: .*|Libs: $libs $libs_private|" "$pc"
              sed -i 's|^Libs.private: .*|Libs.private: |' "$pc"
            fi
          '';
      };
    };

    libtiff = mkUpstreamLibrary {
      package = pkgsCross.libtiff.override {
        libdeflate = self.libdeflate;
        libjpeg = self.libjpeg;
        xz = self.xz;
        zlib = self.zlib;
        zstd = self.zstd;
        libwebp = self.libwebp;
        withLerc = false;
      };
      doCheck = false;
    };

    libwebp = mkUpstreamLibrary {
      package = pkgsCross.libwebp.override {
        threadingSupport = false;
        pngSupport = true;
        libpng = self.libpng;
        jpegSupport = true;
        libjpeg = self.libjpeg;
        tiffSupport = false;
        gifSupport = false;
      };
      doCheck = false;
    };

    imagemagick = mkUpstreamLibrary {
      package = pkgsCross.imagemagick.override {
        bzip2Support = false;
        zlibSupport = true;
        zlib = self.zlib;
        libX11Support = false;
        libXtSupport = false;
        fontconfigSupport = false;
        freetypeSupport = true;
        freetype = self.freetype;
        ghostscriptSupport = false;
        libjpegSupport = true;
        libjpeg = self.libjpeg;
        djvulibreSupport = false;
        lcms2Support = false;
        openexrSupport = false;
        libjxlSupport = false;
        libpngSupport = true;
        libpng = self.libpng;
        liblqr1Support = false;
        libraqmSupport = false;
        librawSupport = false;
        librsvgSupport = false;
        libtiffSupport = true;
        libtiff = self.libtiff;
        libxml2Support = true;
        libxml2 = self.libxml2;
        openjpegSupport = false;
        libwebpSupport = true;
        libwebp = self.libwebp;
        libheifSupport = false;
        fftwSupport = false;
        coreutils = pkgs.coreutils;
        curl = self.curl;
        potrace = pkgs.runCommand "potrace-placeholder" {} ''
          mkdir -p "$out"
        '';
      };
      doCheck = false;
      postPatch = ''
        substituteInPlace MagickCore/delegate.c \
          --replace-fail 'child_pid=(pid_t) fork();' 'child_pid=(pid_t) -1; /* WASIX: fork unsupported */'
      '';
      env = {
        CPPFLAGS = "-I${lib.getDev self.zstd}/include";
        LDFLAGS = "-L${lib.getLib self.zstd}/lib";
      };
      overrideAttrs = old: {
        outputs = ["out"];
        buildInputs = lib.filter (
          input: let
            name = input.pname or input.name or "";
          in
            name != "potrace"
        ) ((old.buildInputs or []) ++ [self.zstd]);
        postInstall = ''
          mkdir -p "$out/include"
          if ls "$out"/include/ImageMagick-* >/dev/null 2>&1; then
            rm -f "$out/include/ImageMagick"
            ln -s "$(basename "$(echo "$out"/include/ImageMagick-* | awk '{ print $1 }')")" "$out/include/ImageMagick"
          fi
        '';
      };
    };

    expat = mkUpstreamLibrary {
      package = pkgsCross.expat;
      doCheck = false;
    };

    readline = mkUpstreamLibrary {
      package = pkgsCross.readline.override {
        ncurses = self.ncurses;
      };
      doCheck = false;
      # readline shares bash's BASH_FUNC_POSIX_SETJMP check (same cache var).
      configureFlags = lib.optionals offMode ["bash_cv_func_sigsetjmp=missing"];
    };

    ncurses = pkgsCross.callPackage ./ncurses {
      inherit nixpkgs toolchain;
    };
  });
  phpLibraries =
    if includePhp
    then
      import ./php {
        inherit pkgs toolchain;
        libraries = baseLibraries;
      }
    else {};
in
  baseLibraries // phpLibraries
