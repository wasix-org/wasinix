# oniguruma provides regex; jq doesn't fork, so no asyncify. jq bakes
# ${tzdata}/share/zoneinfo for its date built-ins; cross tzdata doesn't build
# for WASIX (localtime.c uses getresuid/tzname/...), and zoneinfo is plain
# data, so use the build-platform tzdata. tz-aware date functions just won't
# find the store path at runtime in the sandbox.
{
  final,
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "jq";} (
  helpers.libTweaks {
    # jq's postFixup strips $dev/$man/$doc refs from the binary to break a
    # bin<->dev output cycle; retarget it at jq.wasm, since wasmRename's
    # postInstall renamed $bin/bin/jq before fixup runs.
    postFixup = _: ''
      remove-references-to -t "$dev" -t "$man" -t "$doc" "$bin/bin/jq.wasm"
    '';
  } (prev.jq.override {tzdata = final.buildPackages.tzdata;})
)
