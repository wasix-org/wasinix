{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.textual {
  disabledTests = [
    "test_enter_selects_an_item"
    "test_no_command_palette_worker_droppings"
  ];
}
