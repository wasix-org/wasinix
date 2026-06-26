# gnugrep. pcre2 off (fails on this toolchain); runtimeShellPackage null (don't
# pull a target-side shell). gnulib-tests stripped (not portable to WASIX).
{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "grep";} (
  helpers.libTweaks {
    configureFlags = ["--disable-perl-regexp"];
    postPatch = ''
      sed -i 's:gnulib-tests::g' Makefile.in
    '';
    overrideAttrs = old: {
      patches =
        (old.patches or [])
        ++ [
          ./patches/0001-opendirat-rename-for-wasix-libc-collision.patch
          ./patches/0002a-stdin-lseek-permission-as-nonseekable.patch
          ./patches/0003a-fallback-progname-when-runtime-argv0-is-missing.patch
        ];
    };
  } (prev.gnugrep.override {
    pcre2 = null;
    runtimeShellPackage = null;
  })
)
