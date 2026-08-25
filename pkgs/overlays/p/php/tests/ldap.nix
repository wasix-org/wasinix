{
  entry,
  harnesses,
  packageForEntry,
  packages,
  pkgs,
  ...
}: let
  port =
    9100
    + pkgs.lib.toInt (pkgs.lib.versions.minor (packageForEntry packages entry).version)
    + (
      if pkgs.lib.hasSuffix "-int64" entry.name
      then 100
      else 0
    );
in {
  ldap = harnesses.hostShell {
    name = "${entry.name}-ldap";
    hostPackages = [pkgs.openldap];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    timeout = 900;
    script = ''
      mkdir db
      cat > slapd.conf <<EOF
      include ${pkgs.openldap}/etc/schema/core.schema
      pidfile $PWD/slapd.pid
      argsfile $PWD/slapd.args
      database mdb
      maxsize 1073741824
      suffix "o=wasix"
      rootdn "cn=admin,o=wasix"
      rootpw secret
      directory $PWD/db
      EOF
      cat > entries.ldif <<'EOF'
      dn: o=wasix
      objectClass: top
      objectClass: organization
      o: WASIX

      dn: cn=PHP on WASIX,o=wasix
      objectClass: top
      objectClass: person
      cn: PHP on WASIX
      sn: WASIX
      EOF

      ${pkgs.openldap}/libexec/slapd \
        -f "$PWD/slapd.conf" \
        -h ldap://127.0.0.1:${toString port} >slapd.log 2>&1 &
      slapd_pid=$!
      trap 'kill "$slapd_pid" 2>/dev/null || true; wait "$slapd_pid" 2>/dev/null || true' EXIT

      for _ in $(seq 1 60); do
        ldapwhoami -x -H ldap://127.0.0.1:${toString port} >/dev/null 2>&1 && break
        sleep 1
      done
      ldapadd \
        -x -H ldap://127.0.0.1:${toString port} \
        -D 'cn=admin,o=wasix' -w secret \
        -f entries.ldif

      cp ${./ldap.php} ldap.php
      php ldap.php ${toString port}
    '';
  };
}
