# The example projects anybuild ships (examples/ in its own source) driven by
# the wasix build of anybuild: detection and planning for every one of them,
# the wasix overlay index reaching the python providers, and a real build of the
# templates whose toolchain is nothing but file copying.
#
# Toolchain-bearing templates (node, php, go, python) cannot build here: the
# local build backend expects the toolchain already on PATH, and the guest has
# no node/php/go/uv. The python side is covered natively in python-templates.nix.
{
  pkgs,
  testLib,
  wasmerPkgs,
  crossPkgs,
  pythonRegistry,
}: let
  inherit (pkgs) lib;
  examples = "${crossPkgs.anybuild.src}/examples";

  # Providers whose plan carries the wasix wheel index (python.bzl's cross
  # steps, and mkdocs which builds on them).
  overlayProviders = ["python" "mkdocs"];

  # staticfile is the one provider whose build steps are pure file copying, so
  # it runs to completion with an empty PATH.
  staticTemplates = ["staticfile" "staticfile-redirects" "static-htmlwithjs" "static-nobuild"];

  indexUrl = "http://127.0.0.1:8731/simple";
in {
  # Every template resolves to a provider and plans, with the Anybuild file
  # regenerated from detection rather than read from the committed one.
  plan = testLib.mkWasixRun {
    name = "anybuild-templates-plan";
    nativePkgs = [pkgs.jq pkgs.diffutils];
    wasixPkgs = [wasmerPkgs.anybuild];
    timeout = 1800;
    script = ''
      cp -R ${examples} templates
      chmod -R u+w templates
      mkdir plans

      for template in templates/*; do
        name=$(basename "$template")
        anybuild plan "$template" --wasmer --regenerate --temp-anybuild > "plans/$name.json"
      done

      # A template upstream adds must not be skipped silently. Sort after
      # stripping: ls orders staticfile-redirects.json before staticfile.json.
      ls templates | sort > expected
      ls plans | sed 's/\.json$//' | sort > planned
      diff expected planned

      for plan in plans/*.json; do
        jq -e '(.provider // "") != ""' "$plan" >/dev/null \
          || { echo "anybuild: $plan carries no provider" >&2; exit 1; }
      done
      echo "ok: $(wc -l < planned) templates planned"
    '';
  };

  # The wasix wheel index served over loopback, with anybuild pointed at it: the
  # python providers must carry that exact URL and cross-compile for wasix, and
  # the URL must be a live index rather than an echoed string.
  overlay-index = testLib.mkWasixRun {
    name = "anybuild-templates-overlay-index";
    nativePkgs = [pkgs.python3 pkgs.curl pkgs.jq];
    wasixPkgs = [wasmerPkgs.anybuild];
    wasmerArgs = ["--net"];
    forwardEnv = testLib.defaultForwardEnv ++ ["ANYBUILD_PYTHON_EXTRA_INDEX_URL"];
    timeout = 1800;
    script = ''
      python3 -m http.server 8731 --bind 127.0.0.1 --directory ${pythonRegistry} &
      trap 'kill %1 2>/dev/null || true' EXIT
      for _ in $(seq 1 150); do
        curl -fsS ${indexUrl}/ >/dev/null 2>&1 && break
        sleep 0.2
      done
      curl -fsS ${indexUrl}/ >/dev/null \
        || { echo "anybuild: the wheel index never became ready" >&2; exit 1; }

      export ANYBUILD_PYTHON_EXTRA_INDEX_URL=${indexUrl}
      cp -R ${examples} templates
      chmod -R u+w templates
      mkdir plans
      for template in templates/*; do
        name=$(basename "$template")
        anybuild plan "$template" --wasmer --regenerate --temp-anybuild > "plans/$name.json"
      done

      overlay=0
      for plan in plans/*.json; do
        case "$(jq -r '.provider' "$plan")" in
          ${lib.concatStringsSep "|" overlayProviders}) ;;
          *) continue ;;
        esac
        overlay=$((overlay + 1))
        got=$(jq -r '.config.python_extra_index_url // ""' "$plan")
        [ "$got" = "${indexUrl}" ] \
          || { echo "anybuild: $plan resolves the overlay index to '$got'" >&2; exit 1; }
        cross=$(jq -r '.config.python_cross_platform // ""' "$plan")
        [ "$cross" = wasix_wasm32 ] \
          || { echo "anybuild: $plan cross-compiles for '$cross'" >&2; exit 1; }
      done
      [ "$overlay" -gt 0 ] \
        || { echo "anybuild: no template uses the overlay index" >&2; exit 1; }

      # A served project the templates reach for, proving the configured URL is
      # the index itself and not just a string anybuild echoed back.
      curl -fsS ${indexUrl}/pydantic-core/ | grep -q wasix_wasm32 \
        || { echo "anybuild: the served index has no wasix wheels for pydantic-core" >&2; exit 1; }
      echo "ok: $overlay templates point at the served index"
    '';
  };

  # A real build, end to end, of the templates that need no toolchain: the
  # provider's steps run and the served artifacts match the project's sources.
  static-build = testLib.mkWasixRun {
    name = "anybuild-templates-static-build";
    nativePkgs = [pkgs.diffutils];
    wasixPkgs = [wasmerPkgs.anybuild];
    script = ''
      cp -R ${examples} templates
      chmod -R u+w templates

      for name in ${toString staticTemplates}; do
        anybuild build "templates/$name" --skip-prepare
        served="templates/$name/.anybuild/local/build/opt/static_app"
        if [ ! -d "$served" ]; then
          echo "anybuild: $name built no static_app tree" >&2
          exit 1
        fi
        if [ ! -s "$served/index.html" ]; then
          echo "anybuild: $name served no index.html" >&2
          exit 1
        fi
      done

      # staticfile publishes a subdirectory (Staticfile's root: site), so the
      # served tree must be that directory and not the project root.
      diff -r templates/staticfile/site templates/staticfile/.anybuild/local/build/opt/static_app
      echo "ok: ${toString (builtins.length staticTemplates)} static templates built"
    '';
  };
}
