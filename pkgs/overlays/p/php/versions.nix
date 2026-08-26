{
  historical = {
    php74 = {
      version = "7.4.33";
      hash = "sha256-+tXDSFZNqL3qRiovjAymujYwV4eIj0PhngdKFQNioXs=";
    };
    php81 = {
      version = "8.1.34";
      hash = "sha256-03kBZNWu7r3xHjuAWSAgtQxfiYSoyCgDzo2hnpfJJew=";
    };
  };
  nixpkgs = [
    "php82"
    "php83"
    "php84"
    "php85"
  ];
}
