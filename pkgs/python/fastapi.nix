# fastapi 0.115 caps starlette<0.47 and the set ships 1.3.1, so a rebased 0.115
# takes the starlette history entry that satisfies it instead of the current one.
{
  exposeExtendedPackage,
  packages,
  package,
  lib,
  replaceInputsByName,
}:
exposeExtendedPackage (
  lib.optionalAttrs (lib.versionOlder package.version "0.116") {
    propagatedBuildInputs = replaceInputsByName {
      starlette = packages.sameProfile.starlette.versions."0.46.2";
    };
  }
  // {
    passthru.wasixDeclaredCheckInputs = [
      packages.sameProfile.a2wsgi
      packages.sameProfile.anyio
      packages.sameProfile.dirty-equals
      packages.sameProfile.email-validator
      packages.sameProfile.flask
      packages.sameProfile.httpx2
      packages.sameProfile.inline-snapshot
      packages.sameProfile.itsdangerous
      packages.sameProfile.jinja2
      packages.sameProfile.pydantic-extra-types
      packages.sameProfile.pydantic-settings
      packages.sameProfile.pwdlib
      packages.sameProfile.pyjwt
      packages.sameProfile.pytestCheckHook
      packages.sameProfile.pytest-xdist
      packages.sameProfile.pytest-timeout
      packages.sameProfile.python-multipart
      packages.sameProfile.pyyaml
      packages.sameProfile.typer
    ];
    disabledTests = [
      "test_fastapi_cli"
      "test_frontend_respects_root_path"
      "test_required_list_alias_by_name"
    ];
  }
)
