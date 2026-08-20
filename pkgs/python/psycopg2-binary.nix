# psycopg2-binary for wasix (not in nixpkgs): upstream builds it from the same
# psycopg2 source with the name swapped, so a lock pinning the binary name
# resolves. Its selling point is a bundled libpq; we link the libpq we build
# either way, so this differs from psycopg2 only in the name pip matches.
{
  pyfinal,
  helpers,
  ...
}:
helpers.extendPackage pyfinal.psycopg2 {
  pname = "psycopg2-binary";
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'setup(name="psycopg2"' 'setup(name="psycopg2-binary"'
  '';
}
