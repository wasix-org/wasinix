#!/usr/bin/env bash
# Publish the CI eval map to R2 so future PRs can diff against this commit.
# Run via `nix run .#scripts.publish-eval-map`, which provides aws. Env: AWS_*,
# GITHUB_SHA.
set -euo pipefail

# absent when the eval failed; never publish a broken base
if [ -f eval-map.json ]; then
  aws s3 cp --no-progress eval-map.json \
    "s3://wasinix-cache/eval-maps/$GITHUB_SHA.json" \
    --endpoint-url https://1541b1e8a3fc6ad155ce67ef38899700.r2.cloudflarestorage.com
else
  echo "no eval map (eval failed); skipping publish"
fi
