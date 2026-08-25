# WASIX libc provides iconv; keep the nixpkgs shim rather than GNU libiconv.
# The shim ships no archive because the symbols live in libc.
{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {}
