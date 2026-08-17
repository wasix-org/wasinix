# WASI's SQLite omits dynamic extension loading, but sqlx's umbrella `sqlite`
# feature enables it unconditionally. Keep the rest of that feature bundle.
{...}: {
  edited = [">=0.9.0"];
  forVersion = {...}: {
    patchPhase = ''
      substituteInPlace Cargo.toml \
        --replace-fail '    "sqlite-load-extension",' ""
    '';
  };
}
