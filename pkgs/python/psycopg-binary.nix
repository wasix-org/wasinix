# psycopg-binary for wasix (not in nixpkgs): upstream generates it from
# psycopg_c via tools/ci/copy_to_binary.py (package renamed psycopg_binary,
# __impl__ = "binary"), so `pip install psycopg[binary]` can resolve its
# pinned `psycopg-binary == <version>`. Build it from the same fixed
# psycopg-c our psycopg ships; libpq links statically here, so unlike
# upstream's wheel there is no bundled libpq.so.
{
  exposePackage,
  packages,
}:
exposePackage (
  packages.sameProfile.psycopg.passthru.c.overridePythonAttrs (o: {
    pname = "psycopg-binary";
    # nix-level only (the wheel's METADATA stays dep-free like upstream's):
    # gives the import check psycopg, which the upstream guard requires
    # to be imported first.
    dependencies = [packages.sameProfile.psycopg];
    # replaces the inherited postPatch (cd psycopg_c + fixes); same fixes, on
    # the generated psycopg_binary tree.
    postPatch = ''
      python3 tools/ci/copy_to_binary.py
      cd psycopg_binary

      substituteInPlace pyproject.toml \
        --replace-fail "setuptools ==" "setuptools >="
      substituteInPlace psycopg_binary/_psycopg/endian.pxd \
        --replace-fail 'defined(__linux__) || defined(__CYGWIN__)' \
                       'defined(__linux__) || defined(__CYGWIN__) || defined(__wasi__)'
    '';
  })
)
