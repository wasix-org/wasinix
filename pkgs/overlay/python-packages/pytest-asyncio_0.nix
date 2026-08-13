# 0.26.0's build backend imports the package, leaving bytecode that lands in the
# wheel; a py3-none-any artifact then differs per interpreter and the registry
# refuses the two as one filename with conflicting contents.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  PYTHONDONTWRITEBYTECODE = "1";
}
pyprev.pytest-asyncio_0
