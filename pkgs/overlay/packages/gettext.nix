# renames every installed bin/* to *.wasm (so wasmRename's single-name form
# doesn't fit — done in postInstall).
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  configureFlags = [
    "--disable-java"
    "--disable-csharp"
    "--disable-native-java"
    "--disable-openmp"
    "--disable-acl"
    "--without-emacs"
    "--enable-static"
    "--disable-shared"
  ];
  postPatch = ''
    substituteInPlace \
      gettext-runtime/gnulib-lib/getlocalename_l-unsafe.c \
      gettext-runtime/intl/gnulib-lib/getlocalename_l-unsafe.c \
      gettext-tools/gnulib-lib/getlocalename_l-unsafe.c \
      --replace-fail \
      ' #error "Please port gnulib getlocalename_l-unsafe.c to your platform! Report this to bug-gnulib."' \
      '  return (struct string_with_storage) { "C", STORAGE_INDEFINITE };'
    substituteInPlace gettext-tools/src/msginit.c \
      --replace-fail \
      'username = getlogin ();' \
      'username = NULL;'
  '';
  preConfigure = ''
    cat > "$TMPDIR/config.site" <<'EOF'
    ac_cv_func_posix_spawn=yes
    gl_cv_func_posix_spawn_works=yes
    gl_cv_func_posix_spawn_secure_exec=yes
    gl_cv_func_posix_spawnp_secure_exec=yes
    ac_cv_func_fork=yes
    EOF
    export CONFIG_SITE="$TMPDIR/config.site"
  '';
  overrideAttrs = old: {
    postInstall =
      (old.postInstall or "")
      + ''
        for prog in "$out"/bin/*; do
          [ -f "$prog" ] && mv "$prog" "$prog.wasm"
        done
      '';
  };
} (prev.gettext.override {bashNonInteractive = null;})
