{
  wheel,
  runPython,
  ...
}: {
  api-health = runPython {
    name = "langflow-api-health";
    inherit wheel;
    script = ''
      import asyncio

      from langflow.api.health_check_router import HealthResponse, health, health_check_router

      routes = {route.path for route in health_check_router.routes}
      assert {"/health", "/health_check"} <= routes, routes
      assert asyncio.run(health()) == {"status": "ok"}

      response = HealthResponse(status="ok", chat="ok", db="ok")
      assert not response.has_error(), response
      response.db = "error unavailable"
      assert response.has_error(), response
    '';
  };

  cli = runPython {
    name = "langflow-cli";
    inherit wheel;
    script = ''
      import click
      from typer.main import get_command

      from langflow.__main__ import app

      command = get_command(app)
      assert isinstance(command, click.Group), command
      assert {"run", "lfx"} <= set(command.commands), command.commands
      assert {"run", "serve"} <= set(command.commands["lfx"].commands)
    '';
  };

  launcher-and-frontend = runPython {
    name = "langflow-launcher-and-frontend";
    inherit wheel;
    script = ''
      from pathlib import Path

      import langflow
      from langflow.langflow_launcher import main

      assert callable(main)
      package = Path(langflow.__file__).parent
      indexes = list(package.rglob("index.html"))
      assert indexes, f"built frontend missing below {package}"
    '';
  };

  schemas = runPython {
    name = "langflow-schemas";
    inherit wheel;
    script = ''
      from lfx.schema.data import Data
      from lfx.schema.message import Message
      from lfx.utils.constants import MESSAGE_SENDER_USER

      data = Data(text="hello", count=2)
      assert data.get_text() == "hello"
      assert data.count == 2

      document = data.to_lc_document()
      assert document.page_content == "hello"
      assert document.metadata == {"count": 2}
      assert Data.from_document(document).data == {"count": 2, "text": "hello"}

      message = Message(text="hello", sender=MESSAGE_SENDER_USER, session_id="session")
      restored = Message.model_validate_json(message.model_dump_json())
      assert restored.text == "hello"
      assert restored.sender == MESSAGE_SENDER_USER
      assert restored.session_id == "session"
    '';
  };
}
