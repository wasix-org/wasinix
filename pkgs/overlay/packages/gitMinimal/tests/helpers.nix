{pkgs}: rec {
  gitNative = pkgs.gitMinimal.override {
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

  # Create repos/remote.git (bare, one "hello" commit) and docroot/ via native git.
  setupNativeRemote = ''
    mkdir -p repos source docroot
    ${pkgs.git}/bin/git -C source init --initial-branch=main
    echo "hello" > source/hello.txt
    ${pkgs.git}/bin/git -C source add .
    ${pkgs.git}/bin/git -C source commit -m "initial commit"
    ${pkgs.git}/bin/git init --bare --initial-branch=main repos/remote.git
    ${pkgs.git}/bin/git -C source push ../repos/remote.git HEAD:main
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
      then "${pkgs.git}/bin/git -C repos/remote.git config http.receivepack true"
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
        sleep 1
  '';

  # Start lighttpd on port 8766 (HTTPS). Generates a self-signed cert and
  # copies it to $HOME/server.crt so WASM git can find it via GIT_SSL_CAINFO.
  startLighttpdHttps = {receivePack ? false}: ''
        mkdir -p docroot
        ${makeGitHttpBackendWrapper {inherit receivePack;}}
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
          -keyout server.key -out server.crt -days 1 -nodes \
          -subj "/CN=127.0.0.1"
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
        sleep 1
        cp server.crt "$HOME/server.crt"
        export GIT_SSL_CAINFO=$HOME/server.crt
  '';
}
