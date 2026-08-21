# libraqm (pillow/matplotlib's text shaper) needs harfbuzz core + freetype +
# fribidi, not hb-glib or Graphite shaping. Two optional harfbuzz features pull
# packages that don't build on wasix:
#   - glib (hb-glib): glib's bundled gnulib and GIO assume POSIX facilities
#     wasi-libc lacks (e.g. socket ancillary data).
#   - graphite2: its docs build a cross python env that fails to compile.
# Disable both and drop the inputs rather than port them. Tracked in WASIX-TODO.md.
# Also, harfbuzz forces -fno-exceptions (meson.build + cpp_eh=none), which wasixcc
# rejects in the ehpic PIC profiles (PIC requires wasm-EH); keep exceptions on,
# as numpy does.
{
  exposePackage,
  extendPackage,
  package,
  packages,
  runners,
  profileTraitsOf,
}:
exposePackage (
  let
    lib = packages.sameProfile.lib;
    # tests/utilities link the exception-carrying library and need the C++ EH
    # runtime, which the off profile lacks (std::terminate undefined); build and
    # run them only where EH exists.
    hasEh = (profileTraitsOf packages.sameProfile.stdenv.hostPlatform).eh;
    # Harfbuzz needs an exe_wrapper to run its cross-compiled tests. Use the
    # runtime-free wasix-run stub; the check derivation supplies Wasmer via
    # WASIX_WASMER. Keep it local to avoid set-wide target execution.
    wasixExeWrapper = packages.sameProfile.buildPackages.writeText "wasix-exe-wrapper-cross.ini" ''
      [binaries]
      exe_wrapper = '${runners.rawWasm.unbound}/bin/wasix-run'

      [properties]
      skip_sanity_check = true
    '';
  in
    extendPackage (package.override {
      glib = null;
      withGraphite2 = false;
    }) {
      doCheck = hasEh;
      mesonFlags =
        ["-Dglib=disabled" "-Dgobject=disabled" "-Dcpp_eh=default" "-Dutilities=disabled"]
        ++ [
          (
            if hasEh
            then "-Dtests=enabled"
            else "-Dtests=disabled"
          )
        ]
        ++ (
          if hasEh
          then ["--cross-file=${wasixExeWrapper}"]
          else []
        );
      # Emulated tests overrun meson's 30s default timeout and meson exits 1 on
      # timeouts alone; ninja's `test` target passes no options through to meson,
      # so call meson test directly. --timeout-multiplier keeps per-test timeouts,
      # so a hung test still fails. --num-processes 1: the harness serialises
      # guests via enableParallelChecking, which meson's scheduler ignores.
      checkPhase = ''
        runHook preCheck
        meson test --no-rebuild --print-errorlogs --timeout-multiplier 30 --num-processes 1
        runHook postCheck
      '';
      # meson probes a build-machine archiver (llvm-ar/ar/gar) and dies with
      # "Unknown linker(s)" without one; buildPackages' cc wrapper ships no plain
      # `ar`, hence pkgsBuildBuild.
      nativeBuildInputs = [packages.sameProfile.pkgsBuildBuild.binutils];
      # set/stdenv.nix's shim already strips -fno-exceptions for every EH
      # profile, leaving clang's default (exceptions on); it deliberately does
      # not touch the off profile, so patch meson.build there to keep
      # exceptions on too, matching numpy's approach.
      postPatch = lib.optionalString (!hasEh) ''
        substituteInPlace meson.build \
          --replace-fail "'-fno-exceptions'," "'-fexceptions',"
      '';
    }
)
