{
  exposeExtendedPackage,
  package,
  lib,
}:
exposeExtendedPackage {
  postPatch =
    ''
      matches=()
      while IFS= read -r -d "" file; do
        matches+=("$file")
      done < <(grep -rlZ '\[Errno 2\]' test)
      if [ "''${#matches[@]}" -eq 0 ]; then
        echo "docutils tests contain no errno 2 expectations" >&2
        exit 1
      fi
      substituteInPlace "''${matches[@]}" \
        --replace-fail '[Errno 2]' '[Errno 44]'
    ''
    + lib.optionalString (lib.versionAtLeast package.version "0.19") ''
      substituteInPlace docutils/writers/odf_odt/__init__.py \
        --replace-fail 'subprocess.CalledProcessError, FileNotFoundError, ValueError' \
          'subprocess.CalledProcessError, OSError, ValueError'
    '';
}
