{
  commands,
  harnesses,
  entry,
  ...
}: {
  file-backend = harnesses.wasixShell {
    name = "wasix-sendmail-file-backend";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.grep];
    forwardEnv = harnesses.defaultForwardEnv ++ ["SENDMAIL_FILE_PATH"];
    script = ''
      export SENDMAIL_FILE_PATH="$WASIX_TEST_ROOT/mail.txt"
      printf 'To: recipient@example.com\nSubject: Test\n\nMessage body\n' | sendmail -t

      grep -F 'Envelope-To: recipient@example.com' "$SENDMAIL_FILE_PATH"
      grep -F 'Subject: Test' "$SENDMAIL_FILE_PATH"
      grep -F 'Message body' "$SENDMAIL_FILE_PATH"
    '';
  };
}
