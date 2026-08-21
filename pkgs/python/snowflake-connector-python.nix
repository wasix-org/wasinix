# snowflake-connector-python for wasix. pythonRuntimeDepsCheckHook fails on the
# aws storage extra (boto3/botocore), which is not in the cross closure.
{
  exposeExtendedPackage,
  packages,
  package,
  lib,
}:
exposeExtendedPackage {
  dontCheckRuntimeDeps = true;

  # 3.x imports boto3 from platform_detection at module scope, so the extra is
  # not optional there; 4.0 defers it. 3.x also requires cffi, which 4.0 drops.
  propagatedBuildInputs =
    lib.optionals (lib.versionOlder package.version "4")
    [packages.sameProfile.boto3 packages.sameProfile.cffi];
  # The upstream suite requires credentials, network services, and optional
  # storage backends. The wheel still receives its import check.
  passthru.wasinix.checks.captured.install = false;
}
