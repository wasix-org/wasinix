# wrapt for wasix. _wrappers.c declares its getset getters and setters one argument
# short, UB the native C ABI forgives but wasm's typed function tables trap on
# ("indirect call type mismatch") at the first proxy attribute access.
{exposeExtendedPackage}:
exposeExtendedPackage {
  patches = [./patches/c-slot-signatures.patch];
}
