<?php

function check_value($condition, $message)
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

$port = (int) $argv[1];
$connection = ldap_connect("ldap://127.0.0.1:" . $port);
check_value($connection !== false, "LDAP connect failed");
check_value(ldap_set_option($connection, LDAP_OPT_PROTOCOL_VERSION, 3), "LDAP protocol setup failed");
check_value(ldap_bind($connection, "cn=admin,o=wasix", "secret"), "LDAP bind failed");
$result = ldap_search($connection, "o=wasix", "(cn=PHP on WASIX)", ["cn"]);
check_value($result !== false, "LDAP search failed");
$entries = ldap_get_entries($connection, $result);
check_value($entries["count"] === 1, "wrong LDAP result count");
check_value($entries[0]["cn"][0] === "PHP on WASIX", "wrong LDAP result");

echo "php ldap ok\n";
