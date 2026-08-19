<?php

function check_network($condition, $message)
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

$httpUrl = $argv[1];
$httpsUrl = $argv[2];
$certificate = $argv[3];
$postUrl = $argv[4];

check_network(file_get_contents($httpUrl) === "hello from php network\n", "HTTP stream failed");

$http = parse_url($httpUrl);
$async = stream_socket_client(
    "tcp://" . $http["host"] . ":" . $http["port"],
    $socketError,
    $socketErrorString,
    5,
    STREAM_CLIENT_CONNECT | STREAM_CLIENT_ASYNC_CONNECT
);
check_network($async !== false, "asynchronous connect failed: " . $socketErrorString);
stream_set_blocking($async, true);
fwrite($async, "GET " . $http["path"] . " HTTP/1.0\r\nHost: " . $http["host"] . "\r\n\r\n");
$asyncResponse = stream_get_contents($async);
fclose($async);
check_network(strpos($asyncResponse, "hello from php network\n") !== false, "asynchronous stream failed");

$streamContext = stream_context_create([
    "ssl" => [
        "cafile" => $certificate,
        "verify_peer" => true,
        "verify_peer_name" => true
    ]
]);
check_network(file_get_contents($httpsUrl, false, $streamContext) === "hello from php network\n", "HTTPS stream failed");

$curl = curl_init($httpUrl);
curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
check_network(curl_exec($curl) === "hello from php network\n", "curl HTTP failed: " . curl_error($curl));
curl_close($curl);

$curl = curl_init($httpsUrl);
curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
curl_setopt($curl, CURLOPT_CAINFO, $certificate);
check_network(curl_exec($curl) === "hello from php network\n", "curl HTTPS failed: " . curl_error($curl));
curl_close($curl);

$payload = json_encode(["name" => "PHP"]);
$curl = curl_init($postUrl);
curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
curl_setopt($curl, CURLOPT_POSTFIELDS, $payload);
curl_setopt($curl, CURLOPT_HTTPHEADER, ["Content-Type: application/json"]);
$postResponse = curl_exec($curl);
check_network($postResponse !== false, "curl POST failed: " . curl_error($curl));
check_network(curl_getinfo($curl, CURLINFO_RESPONSE_CODE) === 200, "curl POST status failed");
curl_close($curl);
check_network(json_encode(json_decode($postResponse)) === $payload, "curl POST response failed");

echo "php network client ok\n";
