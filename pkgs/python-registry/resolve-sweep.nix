# One pip resolve per served project against the built index. The integrity walk
# models pip's tag and metadata handling; this runs the real resolver, so it
# catches what the model misses, such as a dependency reached only through an
# extra.
{
  pkgs,
  lib,
  registry,
  testLib,
  # pname -> the interpreter versions whose wheel set carries it
  projectInterpreters,
}: let
  hostPython = pkgs.python3.withPackages (ps: [ps.pip]);

  worklist =
    pkgs.writeText "registry-resolve-worklist"
    (lib.concatStringsSep "\n"
      (lib.mapAttrsToList (project: pyVersions: "${project} ${lib.concatStringsSep " " pyVersions}")
        projectInterpreters)
      + "\n");
in {
  # A project has to resolve on one interpreter, not on all of them: a release
  # states its own supported range, and litellm's `<3.14` is not a defect in the
  # index. Whether a wheel reaches the interpreters it claims is the integrity
  # walk's question, which reads tags and Requires-Python directly.
  resolve-sweep = testLib.mkScriptRun {
    name = "registry-resolve-sweep";
    packages = [hostPython];
    script = ''
      resolve_one() {
        project=$1
        shift
        for py in "$@"; do
          if python3 -m pip install \
            --quiet --no-cache-dir --disable-pip-version-check \
            --platform wasix_wasm32 --implementation cp \
            --python-version "$py" --abi "cp''${py//./}" \
            --only-binary :all: --index-url file://${registry}/simple \
            --dry-run --report /dev/null "$project" >/dev/null 2>&1; then
            return 0
          fi
        done
        echo "  $project (tried python $*)"
      }
      export -f resolve_one

      failures=$(xargs -a ${worklist} -L1 -P "''${NIX_BUILD_CORES:-4}" \
        bash -c 'resolve_one "$@"' _)

      if [ -n "$failures" ]; then
        echo "served, but resolvable on no interpreter:" >&2
        echo "$failures" >&2
        echo "-> the index is the only source a resolver has, so serving a project it cannot install is a dead entry; serve the missing dependency or drop the project." >&2
        exit 1
      fi
      echo "ok: $(wc -l < ${worklist}) projects resolve"
    '';
  };
}
