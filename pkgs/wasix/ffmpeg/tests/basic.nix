{
  testLib,
  wasmerPkgs,
  ...
}: let
  wasix = [wasmerPkgs.ffmpeg];
in {
  version = testLib.mkWasixRun {
    name = "ffmpeg-version";
    wasixPkgs = wasix;
    wasmerArgs = ["--enable-threads"];
    script = "ffmpeg -version";
  };

  transcode = testLib.mkWasixRun {
    name = "ffmpeg-transcode";
    wasixPkgs = wasix;
    wasmerArgs = ["--enable-threads"];
    script = ''
      ffmpeg -v error -f lavfi -i 'sine=frequency=440:duration=0.1' \
        -c:a pcm_s16le tone.wav
      ffprobe -v error -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 tone.wav > codec
      grep -Fx pcm_s16le codec
    '';
  };
}
