# openssl-src supports upstream WASI; WASIX uses the same target without page
# protection, so secure memory must remain disabled.
{...}: {
  edited = [">=300.5.4"];
}
