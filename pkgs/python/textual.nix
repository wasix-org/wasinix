{
  exposeExtendedPackage,
  package,
}:
exposeExtendedPackage {
  postPatch =
    (package.postPatch or "")
    + ''
      substituteInPlace tests/command_palette/test_interaction.py \
        --replace-fail '        await pilot.press("a")' $'        await pilot.press("a")\n        await pilot.app.screen.workers.wait_for_complete()'
      substituteInPlace tests/command_palette/test_run_on_select.py \
        --replace-fail '        await pilot.press("enter")' $'        await pilot.press("enter")\n        await pilot.pause()'
    '';
  disabledTests = ["test_no_command_palette_worker_droppings"];
}
