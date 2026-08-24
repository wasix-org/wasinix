{pkgs}: {
  # Plain HTTP server on port 8765.
  # Serves docroot/hello.txt, docroot/echo.cgi (echoes body), docroot/redirect.cgi (301→/hello.txt).
  startHttpServer = ''
        mkdir -p docroot
        echo "hello" > docroot/hello.txt
        cat > docroot/echo.cgi << 'CGI'
    #!/bin/sh
    printf "Content-Type: text/plain\r\n\r\n"
    ${pkgs.lib.getExe' pkgs.coreutils "cat"}
    CGI
        cat > docroot/redirect.cgi << 'CGI'
    #!/bin/sh
    printf "Status: 301 Moved Permanently\r\nLocation: /hello.txt\r\nContent-Type: text/plain\r\n\r\n"
    CGI
        chmod +x docroot/echo.cgi docroot/redirect.cgi
        cat > lighttpd.conf << EOF
    server.document-root = "$(pwd)/docroot"
    server.port = 8765
    server.bind = "127.0.0.1"
    server.modules = ("mod_cgi")
    server.errorlog = "$(pwd)/lighttpd.log"
    cgi.assign = (".cgi" => "")
    EOF
        ${pkgs.lighttpd}/sbin/lighttpd -D -f lighttpd.conf &
        sleep 1
  '';

  # TLS HTTP server on port 8766. Same docroot as startHttpServer.
  # Copies the self-signed cert to $HOME/server.crt for use with --cacert.
  startHttpsServer = ''
        mkdir -p docroot
        echo "hello" > docroot/hello.txt
        cat > docroot/echo.cgi << 'CGI'
    #!/bin/sh
    printf "Content-Type: text/plain\r\n\r\n"
    ${pkgs.lib.getExe' pkgs.coreutils "cat"}
    CGI
        cat > docroot/redirect.cgi << 'CGI'
    #!/bin/sh
    printf "Status: 301 Moved Permanently\r\nLocation: /hello.txt\r\nContent-Type: text/plain\r\n\r\n"
    CGI
        chmod +x docroot/echo.cgi docroot/redirect.cgi
        ${pkgs.lib.getExe pkgs.openssl} req -x509 -newkey rsa:2048 \
          -keyout server.key -out server.crt -days 1 -nodes \
          -subj "/CN=127.0.0.1" 2>/dev/null
        cat > lighttpd.conf << EOF
    server.document-root = "$(pwd)/docroot"
    server.port = 8766
    server.bind = "127.0.0.1"
    server.modules = ("mod_cgi", "mod_openssl")
    server.errorlog = "$(pwd)/lighttpd.log"
    ssl.engine = "enable"
    ssl.pemfile = "$(pwd)/server.crt"
    ssl.privkey = "$(pwd)/server.key"
    cgi.assign = (".cgi" => "")
    EOF
        ${pkgs.lighttpd}/sbin/lighttpd -D -f lighttpd.conf &
        sleep 1
        cp server.crt "$HOME/server.crt"
  '';
}
