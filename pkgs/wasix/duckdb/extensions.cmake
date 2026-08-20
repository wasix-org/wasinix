# duckdb in-tree extension set. icu (its bundled subset) builds now that
# wasix-libc declares tzname and the double-conversion arch patch marks wasm
# supported (see package.nix), so TIMESTAMPTZ/timezone + collations work.
duckdb_extension_load(autocomplete)
duckdb_extension_load(core_functions)
duckdb_extension_load(icu)
duckdb_extension_load(json)
duckdb_extension_load(parquet)
duckdb_extension_load(tpcds)
duckdb_extension_load(tpch)
