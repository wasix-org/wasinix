{
  entry,
  harnesses,
  pkgs,
  ...
}: {
  mail = harnesses.hostShell {
    name = "${entry.name}-mail";
    hostPackages = [pkgs.gnugrep];
    wasixCommands = builtins.attrValues entry.commands;
    forwardEnv = harnesses.defaultForwardEnv ++ ["SENDMAIL_FILE_PATH"];
    script = ''
      export SENDMAIL_FILE_PATH="$WASIX_TEST_ROOT/mail.txt"
      php -r 'exit(mail("recipient@example.com", "PHP subject", "PHP body") ? 0 : 1);'

      grep -F 'Envelope-To: recipient@example.com' "$SENDMAIL_FILE_PATH"
      grep -F 'Subject: PHP subject' "$SENDMAIL_FILE_PATH"
      grep -F 'PHP body' "$SENDMAIL_FILE_PATH"
    '';
  };
}
