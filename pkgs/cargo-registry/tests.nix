# Checks on the minted registry payload: what a publish would actually upload.
# The wasm server serving it back to cargo end to end is the server package's
# own test, wasix/cargo-registry/tests/serve.nix.
{
  pkgs,
  lib,
  registry,
  manifest,
  cargoRegistryWire,
}: let
  # Zero-dep, so consume resolves offline. Its patch adds the `dl` target env
  # (our -dl triple); the `dl` marker in the built crate proves the patch applied.
  probe = {
    crate = "target-lexicon";
    upstream = "0.13.2";
    marker = "dl";
  };
  entryFor = name: upstream:
    lib.findFirst (c: c.crate == name && c.upstream == upstream)
    (throw "cargo-registry: tests expect a ${name} ${upstream} build")
    manifest.crates;
  probeEntry = entryFor probe.crate probe.upstream;
in {
  # crates.json and the patch tree name the same crates. A mintable crate with
  # no pins resolves to upstream stock with its edits missing, which nothing
  # else reports: the mint just skips it.
  pins = let
    problems =
      map (c: "${c}: edited, but crates.json pins nothing for it") manifest.unpinned
      ++ map (c: "${c}: pinned in crates.json, but nothing mints it") manifest.stray;
  in
    pkgs.runCommand "cargo-registry-test-pins" {} (
      if problems == []
      then "touch $out"
      else ''
        ${lib.concatMapStringsSep "\n" (p: "echo ${lib.escapeShellArg p} >&2") problems}
        echo 'resync with: nix run .#registry -- pins' >&2
        exit 1
      ''
    );

  # Every entry has a well-formed tarball rooted at <name>-<version>, and its
  # wasixVersion matches the packaged [package].version (the index is built from
  # it, so a mismatch publishes the wrong number).
  manifest =
    pkgs.runCommand "cargo-registry-test-manifest" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      python3 - <<'PY'
      import json, pathlib, tarfile, sys

      reg = pathlib.Path("${registry}")
      manifest = json.loads((reg / "manifest.json").read_text())
      failures = []

      listed = set()
      entries = manifest["crates"]
      milestone = max(1, (len(entries) + 9) // 10)
      for index, entry in enumerate(entries, 1):
          if index == 1 or index % milestone == 0 or index == len(entries):
              print(f"checking registry archives: {index}/{len(entries)}", file=sys.stderr, flush=True)
          root = f"{entry['crate']}-{entry['wasixVersion']}"
          path = reg / "crates" / entry["crateFile"]
          listed.add(entry["crateFile"])

          if not path.exists():
              failures.append(f"{root}: manifest lists {entry['crateFile']}, not in crates/")
              continue
          if entry["wasixVersion"] != f"{entry['upstream']}+wasix.{entry['rel']}":
              failures.append(f"{root}: wasixVersion disagrees with upstream+rel")

          with tarfile.open(path, "r:gz") as tar:
              names = tar.getnames()
              manifest_member = f"{root}/Cargo.toml"
              if manifest_member not in names:
                  failures.append(f"{root}: no {manifest_member} in the tarball")
                  continue
              if any(not n.startswith(f"{root}/") for n in names):
                  failures.append(f"{root}: tarball has members outside {root}/")
              body = tar.extractfile(manifest_member).read().decode()

          # cargo's normalized [package].version, the value the index entry gets.
          got = None
          in_package = False
          for line in body.split("\n"):
              stripped = line.strip()
              if stripped.startswith("["):
                  in_package = stripped == "[package]"
                  continue
              if in_package and stripped.startswith("version"):
                  got = stripped.split("=", 1)[1].strip().strip('"')
                  break
          if got != entry["wasixVersion"]:
              failures.append(f"{root}: packaged [package].version is {got!r}, manifest says {entry['wasixVersion']!r}")

      stray = {p.name for p in (reg / "crates").iterdir()} - listed
      if stray:
          failures.append(f"crates/ has tarballs the manifest omits: {sorted(stray)}")

      if failures:
          print("\n".join(failures), file=sys.stderr)
          sys.exit(1)
      print(f"ok: {len(manifest['crates'])} builds, {len(manifest['shadowLimits'])} shadow limits")
      PY
      touch "$out"
    '';

  # Cargo actually takes a minted crate: resolve a plain `"0.13"` requirement
  # against a directory source and compile it. Semver ignores build metadata, so
  # it must land on 0.13.2+wasix.N. runCommandCC: rustc needs a linker.
  consume =
    pkgs.runCommandCC "cargo-registry-test-consume" {
      nativeBuildInputs = [pkgs.cargo pkgs.rustc pkgs.writableTmpDirAsHomeHook];
    } ''
      mkdir -p vendor app/src app/.cargo
      tar xzf "${registry}/crates/${probeEntry.crateFile}" -C vendor

      unpacked="vendor/${probe.crate}-${probeEntry.wasixVersion}"
      # A directory source requires this file; the store path already
      # content-addresses the mint, so an empty map is honest.
      echo '{"files":{}}' > "$unpacked/.cargo-checksum.json"
      grep -q '${probe.marker}' "$unpacked/src/targets.rs" \
        || { echo "cargo-registry: the ${probe.crate} patch is missing from the minted crate" >&2; exit 1; }

      cat > app/Cargo.toml <<'EOF'
      [package]
      name = "consume"
      version = "0.0.0"
      edition = "2021"
      [dependencies]
      ${probe.crate} = "${lib.versions.majorMinor probe.upstream}"
      EOF
      cat > app/.cargo/config.toml <<EOF
      [source.crates-io]
      replace-with = "wasix-mint"
      [source.wasix-mint]
      directory = "$PWD/vendor"
      EOF
      echo 'fn main() {}' > app/src/main.rs

      cd app && cargo build --offline

      got=$(sed -n '/name = "${probe.crate}"/,/^$/p' Cargo.lock | sed -n 's/^version = "\(.*\)"/\1/p')
      [ "$got" = "${probeEntry.wasixVersion}" ] \
        || { echo "cargo-registry: resolved ${probe.crate} $got, expected ${probeEntry.wasixVersion}" >&2; exit 1; }
      echo "ok: \"${lib.versions.majorMinor probe.upstream}\" resolved to $got and compiled"
      touch "$out"
    '';

  # The static sparse index the preview cell deploys: generate it from the
  # real mint, serve it over loopback, and have real cargo resolve and
  # compile the probe through sparse+http. One consume proves the dl
  # template, the +-in-filename URLs, the prefix layout, and the entry shape.
  sparse =
    pkgs.runCommandCC "cargo-registry-test-sparse" {
      nativeBuildInputs = [cargoRegistryWire pkgs.cargo pkgs.rustc pkgs.python3 pkgs.curl pkgs.writableTmpDirAsHomeHook];
    } ''
      port=8737
      base="http://127.0.0.1:$port"
      cargo-registry-wire sparse-index "${registry}" site --base-url "$base" \
        --only "${probe.crate}@${probeEntry.wasixVersion}"
      python3 -m http.server --directory site "$port" &
      server=$!
      trap 'kill "$server" 2>/dev/null || true' EXIT
      for _ in $(seq 1 150); do
        curl -fsS "$base/config.json" >/dev/null 2>&1 && break
        sleep 0.2
      done
      curl -fsS "$base/config.json" >/dev/null

      mkdir -p app/src app/.cargo
      cat > app/Cargo.toml <<'EOF'
      [package]
      name = "consume"
      version = "0.0.0"
      edition = "2021"
      [dependencies]
      ${probe.crate} = {version = "${lib.versions.majorMinor probe.upstream}", registry = "wasix-preview"}
      EOF
      cat > app/.cargo/config.toml <<EOF
      [registries.wasix-preview]
      index = "sparse+$base/"
      EOF
      echo 'fn main() {}' > app/src/main.rs
      ( cd app && CARGO_HOME="$PWD/../cargo-home" cargo build )

      got=$(sed -n '/name = "${probe.crate}"/,/^$/p' app/Cargo.lock | sed -n 's/^version = "\(.*\)"/\1/p')
      [ "$got" = "${probeEntry.wasixVersion}" ] \
        || { echo "sparse index resolved ${probe.crate} $got, expected ${probeEntry.wasixVersion}" >&2; exit 1; }
      echo "ok: sparse+http served ${probe.crate} $got and cargo compiled it"
      touch "$out"
    '';

  # A shadow limit and a build for the same crate+version would contradict:
  # the limit says stock works there, the build says it does not.
  shadowLimits = pkgs.runCommand "cargo-registry-test-shadow-limits" {} (
    let
      collisions =
        lib.filter (
          s:
            lib.any (c: c.crate == s.crate && c.upstream == s.limit) manifest.crates
        )
        manifest.shadowLimits;
    in
      if collisions == []
      then ''
        echo "ok: ${toString (lib.length manifest.shadowLimits)} shadow limits, none colliding with a build"
        touch "$out"
      ''
      else ''
        echo "cargo-registry: ${lib.concatMapStringsSep ", " (s: "${s.crate} ${s.limit}") collisions} is both a shadow limit and a build" >&2
        exit 1
      ''
  );
}
