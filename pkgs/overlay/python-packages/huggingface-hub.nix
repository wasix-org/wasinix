# huggingface-hub for wasix. The full closure (typer's `hf` CLI, hf-xet) builds.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.huggingface-hub {doCheck = false;}
