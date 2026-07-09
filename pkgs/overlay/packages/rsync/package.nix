{
  final,
  prev,
  helpers,
  preferredProfilePackages,
  wasmerDependencies,
  ...
}:
helpers.wasmRename {wasmName = "rsync";} (
  helpers.libTweaks {
    passthru.wasix.shipped = true;
    passthru.wasix.updateNotes = [
      "Recheck wasix-port.patch; drop rsync.h/util1.c fallbacks once rsync or wasix-libc provides the missing WASIX declarations."
    ];
    passthru.wasmer.dependencies = [
      (wasmerDependencies.any preferredProfilePackages.openssh)
    ];
    configureFlags = [
      "--disable-acl-support"
      "--disable-xattr-support"
      "ac_cv_func_getgroups=no"
      "ac_cv_func_fork=yes"
      "ac_cv_func_vfork=yes"
    ];
    env.WASIXCC_WASM_OPT_FLAGS = "--asyncify:-O2";
    postPatch = ''
      mkdir -p wasix-compat
      cp ${../git/wasix-compat/unistd.h} wasix-compat/unistd.h
      cp ${../git/wasix-compat/proc.c} wasix-compat/proc.c
    '';
    preConfigure = ''
      $CC -c wasix-compat/proc.c -o wasix-compat/proc.o
      $AR rcs wasix-compat/libwasix-compat.a wasix-compat/proc.o
      export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE-} -I$PWD/wasix-compat"
      export NIX_LDFLAGS="''${NIX_LDFLAGS-} -L$PWD/wasix-compat -lwasix-compat"
    '';
    patches = [./wasix-port.patch];
    postInstall = ''
      rm -f "$out/bin/rsync-ssl"
    '';
  } (prev.rsync.override {
    inherit (final) libiconv zlib popt;
    enableACLs = false;
    enableLZ4 = false;
    enableOpenSSL = false;
    enableXXHash = false;
    enableZstd = false;
  })
)
