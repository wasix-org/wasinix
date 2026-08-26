{
  commands,
  harnesses,
  entry,
  ...
}: let
  wasix = builtins.attrValues entry.commands;
in {
  version = harnesses.wasixShell {
    name = "ffmpeg-version";
    shell = commands.bash;
    commands = wasix;
    runtime.threads = true;
    script = "ffmpeg -version";
  };

  transcode = harnesses.wasixShell {
    name = "ffmpeg-transcode";
    shell = commands.bash;
    commands = wasix ++ [commands.grep];
    runtime.threads = true;
    script = ''
      ffmpeg -v error -f lavfi -i 'sine=frequency=440:duration=0.1' \
        -c:a pcm_s16le tone.wav
      ffprobe -v error -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 tone.wav > codec
      grep -Fx pcm_s16le codec
    '';
  };
}
