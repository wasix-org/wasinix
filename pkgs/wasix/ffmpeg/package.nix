# FFmpeg's headless preset enables many external codecs and host-oriented
# interfaces. Keep the built-in codecs, formats and filters for a portable
# file-processing CLI; external codec libraries can be added independently.
{
  final,
  prev,
  helpers,
  ...
}: let
  base = prev.ffmpeg-headless.override {
    withHeadlessDeps = false;
    withSmallDeps = false;
    withFullDeps = false;

    buildFfmpeg = true;
    buildFfplay = false;
    buildFfprobe = true;
    buildQtFaststart = false;

    buildAvcodec = true;
    buildAvdevice = true;
    buildAvfilter = true;
    buildAvformat = true;
    buildAvutil = true;
    buildSwresample = true;
    buildSwscale = true;

    withGPL = false;
    withVersion3 = false;
    # The ffmpeg frontend itself depends on FFmpeg's threads capability.
    withMultithread = true;
    withNetwork = false;
    withRuntimeCPUDetection = false;
    withPic = false;

    withDocumentation = false;
    withHtmlDoc = false;
    withManPages = false;
    withPodDoc = false;
    withTxtDoc = false;
  };
in
  helpers.wasmRename {wasmName = "ffmpeg";} (helpers.extendPackage base {
    passthru.wasinix.shipped = true;
    passthru.wasix.updateNotes = [
      {message = "recheck wasi-target.patch; upstream FFmpeg configure should recognize wasi/wasip1 targets";}
    ];
    passthru.wasmer.name = "ffmpeg";
    patches = [./wasi-target.patch];
    nativeBuildInputs = [final.disableWasmOptInConfigureHook];
    configureFlags = [
      "--target_os=wasi"
      "--disable-asm"
      # nixpkgs only maps withMultithread to pthreads on isUnix targets;
      # WASIX has pthreads but is classified separately from Unix.
      "--enable-pthreads"
    ];
    preConfigure = ''
      cat > wasix-flock.c <<'EOF'
      #include <errno.h>
      int flock(int fd, int operation) {
        (void)fd;
        (void)operation;
        errno = ENOSYS;
        return -1;
      }
      EOF
      $CC -c wasix-flock.c -o wasix-flock.o
      export NIX_LDFLAGS="''${NIX_LDFLAGS-} $PWD/wasix-flock.o"
    '';
    postInstall = ''
      mv "$bin/bin/ffprobe" "$bin/bin/ffprobe.wasm"
    '';
  })
