# WASIX libc provides iconv; keep the nixpkgs shim rather than GNU libiconv.
{prev, ...}: prev.libiconv
