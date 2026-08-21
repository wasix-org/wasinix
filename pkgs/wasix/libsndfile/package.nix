{
  exposePackage,
  extendPackage,
  package,
  profileSets,
}:
exposePackage (
  extendPackage (package.override {alsa-lib = null;}) {
    configureFlags = ["--disable-alsa"];
    patches = [./patches/xi-initial-write-length.patch];
    # libtool records some codec deps as `<dir>/libNAME.la` paths wasm-ld can't read.
    postBuild = ''
      deplibs=$(. src/.libs/libsndfile.la >/dev/null 2>&1; printf '%s' "$dependency_libs")
      deplibs=$(printf '%s' "$deplibs" | sed -E 's#(/[^ ]*)/lib([A-Za-z0-9_.+-]+)\.la#-L\1 -l\2#g')
      $CC -shared -Wl,--whole-archive src/.libs/libsndfile.a -Wl,--no-whole-archive \
        -Wl,--export-all $deplibs -o src/.libs/libsndfile.so
    '';
    postInstall = ''
      install -Dm755 src/.libs/libsndfile.so "$out/lib/libsndfile.so"
    '';
    passthru.wasix.supportedProfiles = profileSets.pic;
  }
)
