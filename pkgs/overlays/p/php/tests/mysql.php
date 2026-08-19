<?php

function check_value($condition, $message)
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

$port = (int) $argv[1];
$mysqli = new mysqli("127.0.0.1", "root", "", "mysql", $port);
check_value($mysqli->connect_errno === 0, "mysqli connect failed: " . $mysqli->connect_error);
$mysqli->query("create database php_wasix_mysqli");
$mysqli->select_db("php_wasix_mysqli");
$mysqli->query("create table values_table (id integer primary key, value varchar(16))");
$mysqli->query("insert into values_table values (1, 'foo'), (2, 'bar')");
$mysqliResult = $mysqli->query("select id, value from values_table order by id");
check_value($mysqliResult->fetch_assoc() === ["id" => "1", "value" => "foo"], "mysqli first row failed");
check_value($mysqliResult->fetch_assoc() === ["id" => "2", "value" => "bar"], "mysqli second row failed");
check_value($mysqliResult->fetch_assoc() === null, "mysqli returned an extra row");

$pdo = new PDO("mysql:host=127.0.0.1;port=" . $port, "root", "");
$pdo->exec("create database php_wasix_pdo");
$pdo->exec("use php_wasix_pdo");
$pdo->exec("create table values_table (id integer primary key, value varchar(16) not null)");
$pdo->exec("insert into values_table values (1, 'foo'), (2, 'bar')");
$pdoRows = $pdo->query("select id, value from values_table order by id")->fetchAll(PDO::FETCH_ASSOC);
check_value($pdoRows === [
    ["id" => 1, "value" => "foo"],
    ["id" => 2, "value" => "bar"]
] || $pdoRows === [
    ["id" => "1", "value" => "foo"],
    ["id" => "2", "value" => "bar"]
], "PDO MySQL rows failed");

echo "php mysql ok\n";
