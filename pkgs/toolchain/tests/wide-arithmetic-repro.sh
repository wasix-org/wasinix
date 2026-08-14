#!/usr/bin/env bash
set -euo pipefail

src_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build_dir=$(mktemp -d)
trap 'rm -rf -- "$build_dir"' EXIT

for tool in wasixcc wasmer; do
  command -v "$tool" >/dev/null || {
    echo "$tool must be available on PATH" >&2
    exit 2
  }
done

echo "wasixcc: $(wasixcc --version 2>&1 | head -n 1)"
echo "wasmer:  $(wasmer --version)"

export WASIXCC_RUN_WASM_OPT=no
export WASIXCC_WASM_EXCEPTIONS=yes
export WASIXCC_PIC=no

echo "# With wide-arithmetic"
export WASIXCC_COMPILER_POST_FLAGS=-mwide-arithmetic

wasixcc -O3 "$src_dir/wide-arithmetic-repro.c" -o "$build_dir/repro.wasm"

wasmer run --cranelift "$build_dir/repro.wasm" && echo "success" || echo "error"

echo "# Without wide-arithmetic"
export WASIXCC_COMPILER_POST_FLAGS=-mno-wide-arithmetic

wasixcc -O3 "$src_dir/wide-arithmetic-repro.c" -o "$build_dir/repro.wasm"

wasmer run --cranelift "$build_dir/repro.wasm" && echo "success" || echo "error"
