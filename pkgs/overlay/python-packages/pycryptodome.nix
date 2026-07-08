# pycryptodome for wasix. nixpkgs points _IntegerGMP at gmp's libgmp.so.10, but
# the overlay gmp is static-only (no shared lib), so that ctypes load always
# fails and pycryptodome falls back to the pure-python _IntegerNative anyway.
# Drop the substitution so no dead /nix/store path is baked into the wheel; the
# original find_library("gmp") returns nothing on wasix, same fallback.
{
  pyprev,
  helpers,
  lib,
  ...
}:
helpers.libTweaks {postPatch = lib.const "";} pyprev.pycryptodome
