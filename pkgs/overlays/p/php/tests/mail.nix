{
  crossPkgs,
  helpers,
  makeWasmerPackage,
  pkgs,
  testLib,
  ...
}: let
  versions = import ../versions.nix;
  wasmerPkgs = helpers.mkPhpShims "" {inherit crossPkgs makeWasmerPackage;};
in
  pkgs.lib.mapAttrs' (attr: _: {
    name = "${attr}-mail";
    value = testLib.mkWasixRun {
      name = "${attr}-mail";
      nativePkgs = [pkgs.gnugrep];
      wasixPkgs = [wasmerPkgs.${attr}];
      forwardEnv = testLib.defaultForwardEnv ++ ["SENDMAIL_FILE_PATH"];
      script = ''
        export SENDMAIL_FILE_PATH="$WASIX_TEST_ROOT/mail.txt"
        php -r 'exit(mail("recipient@example.com", "PHP subject", "PHP body") ? 0 : 1);'

        grep -F 'Envelope-To: recipient@example.com' "$SENDMAIL_FILE_PATH"
        grep -F 'Subject: PHP subject' "$SENDMAIL_FILE_PATH"
        grep -F 'PHP body' "$SENDMAIL_FILE_PATH"
      '';
    };
  })
  versions
