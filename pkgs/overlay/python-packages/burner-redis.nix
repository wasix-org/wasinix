# burner-redis builds tokio's multi-thread runtime, which tokio does not offer
# on wasm; the current-thread scheduler is what wasix has, and the client drives
# one runtime from python either way.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace src/lib.rs \
      --replace-fail "Builder::new_multi_thread()" "Builder::new_current_thread()"
  '';
  passthru.wasinix.checks.captured.broken = "graceful-shutdown tests do not complete";
}
pyprev.burner-redis
