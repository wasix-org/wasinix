{pkgs}: rec {
  gitNative = pkgs.git.override {
    nlsSupport = false;
    svnSupport = false;
    guiSupport = false;
    sendEmailSupport = false;
    withLibsecret = false;
    withSsh = false;
    doInstallCheck = false;
    rustSupport = false;
    bash = null;
  };

  # Normalize paths and ANSI codes so native and WASM outputs can be diff'd.
  normalizeGitPaths = pkgs.writeShellScript "normalize-git-paths" ''
    sed -e 's/\r//' \
        -e 's/\x1b\[[0-9;]*m//g' \
        -e 's|Initialized empty Git repository in .*/\.git/|Initialized empty Git repository in TMPDIR/.git/|'
  '';

  # Common setup for all tests: identity, deterministic timestamps, no noise.
  gitSetup = ''
    git config --global user.email "test@example.com"
    git config --global user.name "Test"
    git config --global init.defaultBranch main
    git config --global advice.detachedHead false
    git config --global advice.statusHints false
    git config --global log.decorate false
    export GIT_AUTHOR_DATE="2000-01-01T00:00:00+00:00"
    export GIT_COMMITTER_DATE="2000-01-01T00:00:00+00:00"
  '';

  assertFile = path: expected: ''
    actual=$(<${pkgs.lib.escapeShellArg path})
    if [ "$actual" != ${pkgs.lib.escapeShellArg expected} ]; then
      printf 'unexpected contents of %s: %s\n' ${pkgs.lib.escapeShellArg path} "$actual" >&2
      exit 1
    fi
    printf '%s\n' "$actual"
  '';

  # Create repos/remote.git (bare, one "hello" commit) and docroot/ via native git.
  setupNativeRemote = ''
    mkdir -p repos source docroot
    ${pkgs.lib.getExe pkgs.git} -C source init --initial-branch=main
    echo "hello" > source/hello.txt
    ${pkgs.lib.getExe pkgs.git} -C source add .
    ${pkgs.lib.getExe pkgs.git} -C source commit -m "initial commit"
    ${pkgs.lib.getExe pkgs.git} init --bare --initial-branch=main repos/remote.git
    ${pkgs.lib.getExe pkgs.git} -C source push ../repos/remote.git HEAD:main
  '';

  # Write docroot/git-http-backend wrapper that bakes the env vars in.
  # GIT_HTTP_RECEIVE_PACK env var alone is not reliably inherited through
  # lighttpd's CGI; git config http.receivepack is the authoritative knob.
  makeGitHttpBackendWrapper = {receivePack ? false}: ''
        repos_path=$(realpath repos)
        cat > docroot/git-http-backend << WRAPPER
    #!/bin/sh
    export GIT_HTTP_EXPORT_ALL=1
    export GIT_PROJECT_ROOT=$repos_path
    ${
      if receivePack
      then "export GIT_HTTP_RECEIVE_PACK=1"
      else ""
    }
    exec ${pkgs.git}/libexec/git-core/git-http-backend
    WRAPPER
        chmod +x docroot/git-http-backend
        ${
      if receivePack
      then "${pkgs.lib.getExe pkgs.git} -C repos/remote.git config http.receivepack true"
      else ""
    }
  '';

  # Start lighttpd on port 8765 (HTTP). receivePack enables push.
  startLighttpdHttp = {receivePack ? false}: ''
        mkdir -p docroot
        ${makeGitHttpBackendWrapper {inherit receivePack;}}
        cat > lighttpd.conf << EOF
    server.document-root = "$(pwd)/docroot"
    server.port = 8765
    server.bind = "127.0.0.1"
    server.modules = ("mod_cgi")
    server.errorlog = "/dev/stderr"
    cgi.assign = ("git-http-backend" => "")
    EOF
        ${pkgs.lighttpd}/sbin/lighttpd -D -f lighttpd.conf &
        server_pid=$!
        sleep 1
  '';

  # Start lighttpd on port 8766 (HTTPS). A local CA signs the server certificate
  # so the OpenSSL-backed WASIX client exercises normal chain verification.
  startLighttpdHttps = {receivePack ? false}: ''
        mkdir -p docroot
        ${makeGitHttpBackendWrapper {inherit receivePack;}}
        ${pkgs.lib.getExe pkgs.openssl} req -x509 -newkey rsa:2048 \
          -keyout ca.key -out ca.crt -days 1 -nodes \
          -subj "/CN=Wasinix test CA" \
          -addext "basicConstraints=critical,CA:TRUE" \
          -addext "keyUsage=critical,keyCertSign,cRLSign"
        ${pkgs.lib.getExe pkgs.openssl} req -newkey rsa:2048 \
          -keyout server.key -out server.csr -nodes \
          -subj "/CN=127.0.0.1"
        cat > server.ext << EOF
    basicConstraints=critical,CA:FALSE
    keyUsage=critical,digitalSignature,keyEncipherment
    extendedKeyUsage=serverAuth
    subjectAltName=IP:127.0.0.1
    EOF
        ${pkgs.lib.getExe pkgs.openssl} x509 -req -in server.csr \
          -CA ca.crt -CAkey ca.key -CAcreateserial \
          -out server.crt -days 1 -extfile server.ext
        cat > lighttpd.conf << EOF
    server.document-root = "$(pwd)/docroot"
    server.port = 8766
    server.bind = "127.0.0.1"
    server.modules = ("mod_cgi", "mod_openssl")
    server.errorlog = "/dev/stderr"
    cgi.assign = ("git-http-backend" => "")
    ssl.engine = "enable"
    ssl.pemfile = "$(pwd)/server.crt"
    ssl.privkey = "$(pwd)/server.key"
    EOF
        ${pkgs.lighttpd}/sbin/lighttpd -D -f lighttpd.conf &
        server_pid=$!
        sleep 1
        export GIT_SSL_CAINFO=$WASIX_TEST_ROOT/ca.crt
        export SSL_CERT_FILE=$WASIX_TEST_ROOT/ca.crt
  '';
}
