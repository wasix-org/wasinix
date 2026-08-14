#!/usr/bin/env bash
# Rewrite one grammar's version and hash in package.nix. The grammars share a
# builder and a single attrset, which nix-update cannot address, so each one
# passes its language here through passthru.updateScript.
set -euo pipefail

lang="${1:?usage: update.sh <language>}"
nix_file="$(dirname "$0")/package.nix"

block_field() {
  sed -n "/^    ${lang} = {\$/,/^    };\$/p" "$nix_file" |
    sed -n "s/^      $1 = \"\(.*\)\";\$/\1/p"
}

owner="$(block_field owner)"
old_version="$(block_field version)"
[ -n "$old_version" ] || {
  echo "no grammar '${lang}' in ${nix_file}" >&2
  exit 1
}

if [ -n "$owner" ]; then
  repo="tree-sitter-${lang}"
  tag="$(curl -sSf "https://api.github.com/repos/${owner}/${repo}/releases/latest" | jq -r .tag_name)"
  version="${tag#v}"
  hash="$(nix hash convert --hash-algo sha256 --to sri "$(nix-prefetch-url --unpack --type sha256 \
    "https://github.com/${owner}/${repo}/archive/refs/tags/${tag}.tar.gz" 2>/dev/null)")"
else
  # No repo sources; the release generates the parser, so take the sdist.
  pname="tree_sitter_${lang}"
  version="$(curl -sSf "https://pypi.org/pypi/${pname}/json" | jq -r .info.version)"
  url="$(curl -sSf "https://pypi.org/pypi/${pname}/${version}/json" |
    jq -r '.urls[] | select(.packagetype == "sdist") | .url')"
  hash="$(nix hash convert --hash-algo sha256 --to sri "$(nix-prefetch-url --type sha256 "$url" 2>/dev/null)")"
fi

if [ "$version" = "$old_version" ]; then
  echo "tree-sitter-${lang}: already at ${version}"
  exit 0
fi

sed -i \
  -e "/^    ${lang} = {\$/,/^    };\$/ s|^      version = \".*\";\$|      version = \"${version}\";|" \
  -e "/^    ${lang} = {\$/,/^    };\$/ s|^      hash = \".*\";\$|      hash = \"${hash}\";|" \
  "$nix_file"

echo "tree-sitter-${lang}: ${old_version} -> ${version}"
