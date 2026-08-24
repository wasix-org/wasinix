{
  lib,
  version,
  int64,
  serverSnapshot,
}: let
  atLeast = lib.versionAtLeast version;
  older = lib.versionOlder version;
  between = lower: upper: atLeast lower && older upper;

  buildPatches =
    [./build/readline-static-cli.patch]
    ++ lib.optional (older "8.2") ./build/fopencookie-seeker-pre82.patch
    ++ lib.optional (between "8.2" "8.4") ./build/gd-cross-format-cache-pre84.patch;

  runtimePatches =
    [
      ./runtime/optional-getgroups.patch
      ./runtime/network-blocking-connect.patch
      ./runtime/sockets-wasix-features.patch
      (
        if older "8.2"
        then ./runtime/sockets-optional-so-debug-pre82.patch
        else ./runtime/sockets-optional-so-debug.patch
      )
    ]
    ++ lib.optional int64 ./runtime/wasix-int64.patch
    ++ lib.optional (atLeast "8.1") ./runtime/zend-extensions-wasi.patch
    ++ lib.optional (older "8.0") ./runtime/zend-extensions-wasi-74.patch
    ++ lib.optional (atLeast "8.4") ./runtime/fd-table-size.patch
    ++ lib.optional (between "8.2" "8.4") ./runtime/fd-table-size-pre84.patch
    ++ lib.optional (older "8.2") ./runtime/fd-table-size-pre82.patch
    ++ [
      ./runtime/fileinfo-disable-fifo.patch
      ./runtime/mysqlnd-localhost-tcp.patch
    ]
    ++ lib.optional (atLeast "8.2") ./runtime/zend-allocator-madvise.patch
    ++ lib.optional (older "8.2") ./runtime/zend-allocator-madvise-pre82.patch
    ++ lib.optional (atLeast "8.4") ./runtime/posix-spawn-proc-open.patch
    ++ lib.optional (between "8.3" "8.4") ./runtime/posix-spawn-proc-open-83.patch
    ++ lib.optional (between "8.1" "8.3") ./runtime/posix-spawn-81-82.patch
    ++ lib.optional (older "8.0") ./runtime/posix-spawn-74.patch
    ++ lib.optional (atLeast "8.4") ./runtime/random-getrandom.patch
    ++ lib.optional (between "8.3" "8.4") ./runtime/random-getrandom-pre84.patch
    ++ lib.optional (between "8.2" "8.3") ./runtime/random-getrandom-82.patch
    ++ lib.optional (between "8.1" "8.2") ./runtime/random-getrandom-81.patch
    ++ lib.optional (older "8.0") ./runtime/random-getrandom-74.patch
    ++ lib.optional (between "8.1" "8.4") ./runtime/fibers-wasix-pre84.patch
    ++ lib.optional (atLeast "8.4") ./runtime/fibers-wasix.patch
    ++ lib.optionals (older "8.0") [
      ./runtime/setjmp-off-74.patch
      ./runtime/sockets-optional-sock-rdm-74.patch
    ];

  serverSnapshotPatches =
    lib.optional (serverSnapshot && older "8.5") ./server-snapshot/cli-81-84.patch
    ++ lib.optional (atLeast "8.5") ./server-snapshot/cli-85.patch
    ++ lib.optional serverSnapshot (
      if older "8.2"
      then ./server-snapshot/server-81.patch
      else if older "8.3"
      then ./server-snapshot/server-82.patch
      else if older "8.4"
      then ./server-snapshot/server-83.patch
      else ./server-snapshot/server-84.patch
    );

  opcachePatches =
    lib.optional (older "8.5") ./opcache/optional-sys-ipc.patch
    ++ lib.optional (atLeast "8.2") ./opcache/wasix.patch
    ++ lib.optional (between "8.1" "8.2") ./opcache/wasix-81.patch
    ++ lib.optional (older "8.0") ./opcache/wasix-74.patch
    ++ lib.optional (older "8.0") ./opcache/static-74.patch
    ++ lib.optional (between "8.1" "8.2") ./opcache/static-81.patch
    ++ lib.optional (between "8.2" "8.3") ./opcache/static-82.patch
    ++ lib.optional (between "8.3" "8.4") ./opcache/static-83.patch
    ++ lib.optional (between "8.4" "8.5") ./opcache/static-84.patch
    ++ lib.optional (between "8.1" "8.4") ./opcache/mmap-cross.patch
    ++ lib.optional (older "8.0") ./opcache/mmap-cross-74.patch
    ++ lib.optional (atLeast "8.3") ./opcache/preload-wasix.patch
    ++ lib.optional (older "8.3") ./opcache/preload-wasix-pre83.patch;

  compatibilityPatches = lib.optionals (older "8.0") [
    ./compat/php74/cross-phar.patch
    ./compat/php74/libxml-2.15.patch
    ./compat/php74/openssl-3.6.patch
    ./compat/php74/pdo-odbc-size-t.patch
  ];
in {
  source = buildPatches ++ runtimePatches ++ serverSnapshotPatches ++ opcachePatches ++ compatibilityPatches;
  testRunner =
    if older "8.0"
    then ./test-runner/sharding-pre80.patch
    else ./test-runner/sharding.patch;
}
