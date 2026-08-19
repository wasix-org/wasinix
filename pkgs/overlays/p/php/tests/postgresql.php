<?php

$port = $argv[1];
$pgsql = pg_connect("host=127.0.0.1 port=" . $port . " user=postgres dbname=postgres");
if ($pgsql === false) {
    throw new RuntimeException("pg_connect failed");
}
pg_query($pgsql, "create database php_wasix_pgsql");
pg_close($pgsql);
$pgsql = pg_connect("host=127.0.0.1 port=" . $port . " user=postgres dbname=php_wasix_pgsql");
if ($pgsql === false) {
    throw new RuntimeException("pg_connect to created database failed");
}
pg_query($pgsql, "create table values_table (id integer primary key, value text not null)");
pg_query_params($pgsql, "insert into values_table values ($1, $2), ($3, $4)", [1, "foo", 2, "bar"]);
$pgsqlResult = pg_query($pgsql, "select id, value from values_table order by id");
if (pg_fetch_assoc($pgsqlResult) !== ["id" => "1", "value" => "foo"] ||
    pg_fetch_assoc($pgsqlResult) !== ["id" => "2", "value" => "bar"] ||
    pg_fetch_assoc($pgsqlResult) !== false) {
    throw new RuntimeException("pgsql rows failed");
}

$pdo = new PDO("pgsql:host=127.0.0.1;port=" . $port . ";dbname=postgres", "postgres");
$pdo->exec("create database php_wasix_pdo");
$pdo = new PDO("pgsql:host=127.0.0.1;port=" . $port . ";dbname=php_wasix_pdo", "postgres");
$pdo->exec("create table values_table (id integer primary key, value text not null)");
$pdo->exec("insert into values_table values (1, 'foo'), (2, 'bar')");
$pdoRows = $pdo->query("select id, value from values_table order by id")->fetchAll(PDO::FETCH_ASSOC);
if ($pdoRows !== [
    ["id" => 1, "value" => "foo"],
    ["id" => 2, "value" => "bar"]
] && $pdoRows !== [
    ["id" => "1", "value" => "foo"],
    ["id" => "2", "value" => "bar"]
]) {
    throw new RuntimeException("PDO PostgreSQL rows failed");
}

echo "php PostgreSQL ok\n";
