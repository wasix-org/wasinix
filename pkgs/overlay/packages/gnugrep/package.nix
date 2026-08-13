# gnugrep with -P (PCRE). pcre2 resolves to the overlay's pcre2 through the
# fixpoint, so don't null it out. runtimeShellPackage null (no target-side
# shell); gnulib-tests stripped (not portable).
{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {
  wasmName = "grep";
  posixAlias = true;
} (
  helpers.libTweaks {
    passthru.wasix.shipped = true;
    postPatch = ''
      sed -i 's:gnulib-tests::g' Makefile.in
    '';
    patches = [
      ./patches/0001-opendirat-rename-for-wasix-libc-collision.patch
      ./patches/0002a-stdin-lseek-permission-as-nonseekable.patch
      ./patches/0003a-fallback-progname-when-runtime-argv0-is-missing.patch
    ];
  } (prev.gnugrep.override {
    runtimeShellPackage = null;
  })
)
