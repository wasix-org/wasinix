# sentencepiece for wasix, the C++ tokenizer behind the python wheel. gperftools has
# no wasm32 port: basictypes.h #errors out on the unknown architecture and its logger
# writes through raw syscall(SYS_write).
{
  exposePackage,
  extendPackage,
  package,
  profileSets,
}:
exposePackage (
  extendPackage (package.override {withGPerfTools = false;}) {
    cmakeFlags = ["-DSPM_ENABLE_SHARED=OFF"];
    # protobuf-lite is vendored into libsentencepiece.a, so Requires.private makes
    # `pkg-config sentencepiece` fail on the missing protobuf-lite.pc.
    postPatch = ''
      substituteInPlace sentencepiece.pc.in \
        --replace-fail 'Requires.private: @libprotobuf_lite@' ""
    '';
    passthru.wasix.supportedProfiles = profileSets.withEh;
  }
)
