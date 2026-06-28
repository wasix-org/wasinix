# gnugrep with -P (PCRE). pcre2 auto-threads to our overlay's pcre2 (the one that
# builds) through the package-set fixpoint — just don't null it out. runtimeShell-
# Package null (don't pull a target-side shell). gnulib-tests stripped (not portable).
{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "grep";} (
  helpers.libTweaks {
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
