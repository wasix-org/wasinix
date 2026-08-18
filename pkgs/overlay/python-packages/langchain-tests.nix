# This package is a test dependency whose pytest hook cannot run while the
# cross package is being built without a Wasmer runtime.
{pyprev, ...}:
pyprev.langchain-tests.overridePythonAttrs (_: {dontUsePytestCheck = true;})
