# snowflake-connector-python for wasix. pythonRuntimeDepsCheckHook fails on the
# aws storage extra (boto3/botocore), which is not in the cross closure.
{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks {
  dontCheckRuntimeDeps = true;

  # 3.x imports boto3 from platform_detection at module scope, so the extra is
  # not optional there; 4.0 defers it.
  propagatedBuildInputs =
    lib.optionals (lib.versionOlder pyprev.snowflake-connector-python.version "4")
    [pyfinal.boto3];
}
pyprev.snowflake-connector-python
