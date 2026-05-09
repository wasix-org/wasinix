{
  toolchain,
  gettext,
  ...
}:
(gettext.override {
  # bashNonInteractive is propagated into the closure as a runtime shell dep;
  # not needed for the WASIX build.
  bashNonInteractive = null;
}).overrideAttrs (old: {
  postPatch =
    (old.postPatch or "")
    + ''
      # WASIX has a native locale_t so GNULIB_defined_locale_t=0, but none of
      # the platform guards (glibc, BSD, …) match wasm32-wasi, so the #else
      # #error fires. No configure variable fixes this safely; stub the
      # unrecognised-platform branch to return "C".
      substituteInPlace \
        gettext-runtime/gnulib-lib/getlocalename_l-unsafe.c \
        gettext-runtime/intl/gnulib-lib/getlocalename_l-unsafe.c \
        gettext-tools/gnulib-lib/getlocalename_l-unsafe.c \
        --replace-fail \
        ' #error "Please port gnulib getlocalename_l-unsafe.c to your platform! Report this to bug-gnulib."' \
        '  return (struct string_with_storage) { "C", STORAGE_INDEFINITE };'
      # getlogin is declared in the WASIX sysroot headers but not in any sysroot
      # library; NULL lets the existing if-guard skip the block at runtime.
      substituteInPlace gettext-tools/src/msginit.c \
        --replace-fail \
        'username = getlogin ();' \
        'username = NULL;'
    '';
  preConfigure =
    (old.preConfigure or "")
    + ''
      ${toolchain.commonPreConfigure}
      #
      # ac_cv_func_posix_spawn / gl_cv_func_posix_spawn_works: WASIX sysroot
      # provides posix_spawn via proc_spawn. By default it'll try to use fork(),
      # which is not in the WASIX sysroot, so we tell it to use posix_spawn instead.
      cat > "$TMPDIR/config.site" <<'EOF'
      ac_cv_func_posix_spawn=yes
      gl_cv_func_posix_spawn_works=yes
      gl_cv_func_posix_spawn_secure_exec=yes
      gl_cv_func_posix_spawnp_secure_exec=yes
      ac_cv_func_fork=yes
      EOF
      export CONFIG_SITE="$TMPDIR/config.site"
    '';
  configureFlags =
    (old.configureFlags or [])
    ++ [
      "--host=${toolchain.host}"
      "--disable-java"
      "--disable-csharp"
      "--disable-native-java"
      "--disable-openmp"
      "--disable-acl"
      "--without-emacs"
      "--enable-static"
      "--disable-shared"
    ];
  doCheck = false;
  hardeningDisable = ["all"];
  postInstall =
    (old.postInstall or "")
    + ''
      for prog in "$out"/bin/*; do
        [ -f "$prog" ] && mv "$prog" "$prog.wasm"
      done
    '';
})
