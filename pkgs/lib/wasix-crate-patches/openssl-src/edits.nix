# openssl-src supports upstream WASI; WASIX uses the same target without page
# protection, so secure memory must remain disabled. The 300.4 floor is the same
# edit against that tree; releases between the two are unvetted.
_: {
  edited = ["=300.4.1+3.4.0" ">=300.5.4"];
}
