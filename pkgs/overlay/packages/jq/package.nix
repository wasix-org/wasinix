# jq: a JSON processor. oniguruma (a same-profile lib we package) provides regex;
# jq doesn't fork, so no asyncify. Shipped as a webc CLI.
#
# jq bakes ${tzdata}/share/zoneinfo for its date built-ins. Cross tzdata doesn't
# build for WASIX (localtime.c uses getresuid/tzname/...), but zoneinfo is plain
# data — point jq at the build-platform tzdata so it builds; tz-aware date
# functions just won't find the store path at runtime in the sandbox.
{
  final,
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "jq";} (
  helpers.libTweaks {
    # jq's postFixup strips $dev/$man/$doc refs from the binary to break a bin<->dev
    # output cycle (load-bearing) — retarget it at jq.wasm, since wasmRename's
    # postInstall renamed $bin/bin/jq before fixup runs.
    overrideAttrs = _old: {
      postFixup = ''
        remove-references-to -t "$dev" -t "$man" -t "$doc" "$bin/bin/jq.wasm"
      '';
    };
  } (prev.jq.override {tzdata = final.buildPackages.tzdata;})
)
