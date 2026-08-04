# huggingface-hub for wasix. The full closure (typer's `hf` CLI, hf-xet) builds.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {doCheck = false;} pyprev.huggingface-hub
