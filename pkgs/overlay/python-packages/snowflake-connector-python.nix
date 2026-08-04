# snowflake-connector-python for wasix. pythonRuntimeDepsCheckHook fails on the
# aws storage extra (boto3/botocore), which is not in the cross closure.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  dontCheckRuntimeDeps = true;
}
pyprev.snowflake-connector-python
