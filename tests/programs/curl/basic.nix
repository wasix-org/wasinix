{
  pkgs,
  wasmerPkgs,
  testLib,
  helpers,
}: let
  inherit (helpers) startHttpServer startHttpsServer;
  nativeCurl = [pkgs.curl];
  wasixCurl = [wasmerPkgs.curl];
in {
  version = testLib.mkWasixRun {
    name = "curl-version";
    wasixPkgs = wasixCurl;
    script = "curl --version";
  };

  http-get = testLib.mkScriptComparison {
    name = "curl-http-get";
    nativePkgs = nativeCurl ++ [pkgs.lighttpd];
    wasixPkgs = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpServer}
      curl -s http://127.0.0.1:8765/hello.txt
    '';
  };

  http-post = testLib.mkScriptComparison {
    name = "curl-http-post";
    nativePkgs = nativeCurl ++ [pkgs.lighttpd];
    wasixPkgs = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpServer}
      curl -s -X POST -d "hello world" http://127.0.0.1:8765/echo.cgi
    '';
  };

  http-redirect = testLib.mkScriptComparison {
    name = "curl-http-redirect";
    nativePkgs = nativeCurl ++ [pkgs.lighttpd];
    wasixPkgs = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpServer}
      curl -s -L http://127.0.0.1:8765/redirect.cgi
    '';
  };

  https-get = testLib.mkScriptComparison {
    name = "curl-https-get";
    nativePkgs = nativeCurl ++ [pkgs.lighttpd pkgs.openssl];
    wasixPkgs = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpsServer}
      curl -s --cacert "$HOME/server.crt" https://127.0.0.1:8766/hello.txt
    '';
  };

  https-post = testLib.mkScriptComparison {
    name = "curl-https-post";
    nativePkgs = nativeCurl ++ [pkgs.lighttpd pkgs.openssl];
    wasixPkgs = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpsServer}
      curl -s --cacert "$HOME/server.crt" -X POST -d "hello world" https://127.0.0.1:8766/echo.cgi
    '';
  };

  https-redirect = testLib.mkScriptComparison {
    name = "curl-https-redirect";
    nativePkgs = nativeCurl ++ [pkgs.lighttpd pkgs.openssl];
    wasixPkgs = wasixCurl;
    wasmerArgs = ["--net"];
    script = ''
      ${startHttpsServer}
      curl -s -L --cacert "$HOME/server.crt" https://127.0.0.1:8766/redirect.cgi
    '';
  };
}
