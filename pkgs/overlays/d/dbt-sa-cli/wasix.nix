# dbt's Fusion engine, the binary PyPI publishes as both dbt-core 2.x and
# dbt-core-experimental-parser (release-v2.yml packs one build under two
# distribution names). Python dbt-core 1.12 requires the parser distribution, so
# the wheel needs this.
{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  # driver_parameters() names the prebuilt ADBC driver to fetch and defines its
  # OS only for linux/macos/windows. No wasm driver is published, and claiming a
  # linux one would download an ELF this cannot dlopen, so name the target
  # honestly: the download then fails instead of loading the wrong artifact.
  patches = [
    ./patches/dbt-adbc-wasi-driver-triplet.patch
    # The docs server waits on tokio::signal, which the wasix tokio does not
    # build; wasmer delivers no signal to wait on either (WASIX-TODO.md), so the
    # wasi arm parks instead of pretending a shutdown can arrive.
    ./patches/dbt-docs-server-wasi-shutdown.patch
    # Both symlink wrappers reach for the unix call, which WASIX std exposes as
    # the path-typed extension instead; tokio has no wasi symlink at all, so the
    # async wrapper defers to the sync one.
    ./patches/dbt-common-wasi-symlink.patch
    # The git client drives tokio::process, which the wasix tokio does not
    # build. Spawning works here, so the wasi arm runs std's Command behind the
    # async signature the call site expects.
    ./patches/dbt-deps-wasi-git-command.patch
    # Same missing tokio::signal, in the cancellation path: the Ctrl+C source
    # becomes a future that never fires, leaving fail-fast as the only one.
    ./patches/dbt-main-wasi-ctrl-c.patch
  ];

  # dbt-state's build script generates prost bindings, so protoc runs on the
  # build host; prost-build looks it up by env before PATH.
}
