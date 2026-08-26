{
  entry,
  harnesses,
  packageForEntry,
  packages,
  pkgs,
  ...
}: let
  php = packageForEntry packages entry;
  inherit (php) libphp;
  program = packages.sameProfile.stdenv.mkDerivation {
    pname = "${entry.name}-libphp-smoke";
    inherit (php) version;
    dontUnpack = true;
    buildInputs = [libphp];
    buildPhase = ''
      runHook preBuild
      $CC $(${libphp}/bin/php-config --includes) ${./embed.c} \
        -L${libphp}/lib -lphp \
        $(${libphp}/bin/php-config --ldflags) \
        $(${libphp}/bin/php-config --libs) \
        -o php-embed-smoke.wasm
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 php-embed-smoke.wasm -t "$out/bin"
      runHook postInstall
    '';
    passthru.wasmer.name = "php-embed-smoke";
  };
in
  pkgs.lib.optionalAttrs (pkgs.lib.versionAtLeast php.version "8.1") {
    libphp-layout = assert libphp.ztsSupport;
      pkgs.runCommand "${entry.name}-libphp" {} ''
        test -f ${libphp}/lib/libphp.a
        test -f ${libphp}/include/php/sapi/embed/php_embed.h
        grep -Fx '#define ZTS 1' ${libphp}/include/php/main/php_config.h
        test ! -e ${libphp}/bin/php.wasm
        touch "$out"
      '';

    libphp = harnesses.hostShell {
      name = "${entry.name}-libphp";
      wasixCommands = [(harnesses.packageCommand {package = program;})];
      script = ''
        test "$(php-embed-smoke)" = "php embed ok"
      '';
    };
  }
