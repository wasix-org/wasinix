# fastapi 0.115 caps starlette<0.47 and the set ships 1.3.1, so a rebased 0.115
# takes the starlette history entry that satisfies it instead of the current one.
{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks (
  lib.optionalAttrs (lib.versionOlder pyprev.fastapi.version "0.116") {
    propagatedBuildInputs = helpers.replaceInputsByName {
      starlette = pyfinal.starlette_0_46_2;
    };
  }
  // {
    passthru.wasixDeclaredCheckInputs = [
      pyfinal.a2wsgi
      pyfinal.anyio
      pyfinal.dirty-equals
      pyfinal.email-validator
      pyfinal.flask
      pyfinal.httpx2
      pyfinal.inline-snapshot
      pyfinal.itsdangerous
      pyfinal.jinja2
      pyfinal.pydantic-extra-types
      pyfinal.pydantic-settings
      pyfinal.pwdlib
      pyfinal.pyjwt
      pyfinal.pytestCheckHook
      pyfinal.pytest-xdist
      pyfinal.pytest-timeout
      pyfinal.python-multipart
      pyfinal.pyyaml
      pyfinal.typer
    ];
    disabledTests = [
      "test_fastapi_cli"
      "test_frontend_respects_root_path"
      "test_required_list_alias_by_name"
    ];
  }
)
pyprev.fastapi
