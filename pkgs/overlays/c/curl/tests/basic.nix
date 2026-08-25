{
  pkgs,
  entry,
  harnesses,
  helpers,
}: let
  inherit (helpers) startHttpServer startHttpsServer;
  nativeCurl = [pkgs.curl];
  wasixCurl = builtins.attrValues entry.commands;
in {
  version = harnesses.hostShell {
    name = "curl-version";
    wasixCommands = wasixCurl;
    script = "curl --version";
  };

  http-get = harnesses.compareShells {
    name = "curl-http-get";
    hostPackages = nativeCurl ++ [pkgs.lighttpd];
    wasixCommands = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpServer}
      curl -s http://127.0.0.1:8765/hello.txt
    '';
  };

  http-post = harnesses.compareShells {
    name = "curl-http-post";
    hostPackages = nativeCurl ++ [pkgs.lighttpd];
    wasixCommands = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpServer}
      curl -s -X POST -d "hello world" http://127.0.0.1:8765/echo.cgi
    '';
  };

  http-redirect = harnesses.compareShells {
    name = "curl-http-redirect";
    hostPackages = nativeCurl ++ [pkgs.lighttpd];
    wasixCommands = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpServer}
      curl -s -L http://127.0.0.1:8765/redirect.cgi
    '';
  };

  https-get = harnesses.compareShells {
    name = "curl-https-get";
    hostPackages = nativeCurl ++ [pkgs.lighttpd pkgs.openssl];
    wasixCommands = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpsServer}
      curl -s --cacert "$HOME/server.crt" https://127.0.0.1:8766/hello.txt
    '';
  };

  https-post = harnesses.compareShells {
    name = "curl-https-post";
    hostPackages = nativeCurl ++ [pkgs.lighttpd pkgs.openssl];
    wasixCommands = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpsServer}
      curl -s --cacert "$HOME/server.crt" -X POST -d "hello world" https://127.0.0.1:8766/echo.cgi
    '';
  };

  https-redirect = harnesses.compareShells {
    name = "curl-https-redirect";
    hostPackages = nativeCurl ++ [pkgs.lighttpd pkgs.openssl];
    wasixCommands = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpsServer}
      curl -s -L --cacert "$HOME/server.crt" https://127.0.0.1:8766/redirect.cgi
    '';
  };
}
