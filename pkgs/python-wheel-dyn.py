"""Check a wheel's extensions import nothing that is never exported (python-wheels.nix `dynamic`).

A wasm PIC extension resolves data and function symbols it does not define
through the `GOT.mem` and `GOT.func` import modules, and wasm-ld turns an
undefined symbol into one of those rather than failing the link. A missing
library therefore builds cleanly and only breaks when wasmer loads the module,
as `Unresolved global 'GOT.mem'.<symbol> due to: Missing export`.

Walk every extension in the wheel, collect what it asks the loader for, and
require some module the loader will have (the interpreter, or another extension
in the closure) to export it.

Usage: python-wheel-dyn.py <interpreter wasm> <site-packages dir>...
"""

import sys
from pathlib import Path

# Data symbols only. A `GOT.func` import can be satisfied by the module's own
# indirect call machinery at load (aiohttp's llhttp callbacks are imported that
# way and resolve fine), so requiring an export for one reports working wheels.
GOT_MODULES = ("GOT.mem",)

# `_ZTH*` is a thread-local initializer, which the runtime resolves rather than
# another module; the interpreter imports one itself.
RUNTIME_PROVIDED = ("_ZTH",)


def read_uleb(data, pos):
    result = shift = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7


def read_name(data, pos):
    length, pos = read_uleb(data, pos)
    return data[pos : pos + length].decode("utf-8", "replace"), pos + length


def sections(data):
    """(id, body) for each section; a wasm file is a header then sections."""
    if data[:4] != b"\0asm":
        return
    pos = 8
    while pos < len(data):
        sec_id = data[pos]
        size, pos = read_uleb(data, pos + 1)
        yield sec_id, data[pos : pos + size]
        pos += size


def imports_and_exports(path):
    """Symbols the module asks the loader for, and the symbols it offers."""
    data = path.read_bytes()
    wanted, offered = set(), set()
    for sec_id, body in sections(data):
        if sec_id == 2:  # import
            count, pos = read_uleb(body, 0)
            for _ in range(count):
                module, pos = read_name(body, pos)
                field, pos = read_name(body, pos)
                kind = body[pos]
                pos += 1
                if kind == 0:  # func: type index
                    _, pos = read_uleb(body, pos)
                elif kind == 1:  # table
                    pos += 1
                    limits = body[pos]
                    pos += 1
                    _, pos = read_uleb(body, pos)
                    if limits & 1:
                        _, pos = read_uleb(body, pos)
                elif kind == 2:  # memory
                    limits = body[pos]
                    pos += 1
                    _, pos = read_uleb(body, pos)
                    if limits & 1:
                        _, pos = read_uleb(body, pos)
                elif kind == 3:  # global
                    pos += 2
                elif kind == 4:  # tag
                    pos += 1
                    _, pos = read_uleb(body, pos)
                if module in GOT_MODULES and not field.startswith(RUNTIME_PROVIDED):
                    wanted.add(field)
        elif sec_id == 7:  # export
            count, pos = read_uleb(body, 0)
            for _ in range(count):
                field, pos = read_name(body, pos)
                pos += 1
                _, pos = read_uleb(body, pos)
                offered.add(field)
    return wanted, offered


def main() -> None:
    interpreter, *roots = sys.argv[1:]
    extensions = []
    for root in roots:
        extensions += sorted(Path(root).rglob("*.so"))

    # The interpreter is an export source, not a subject: what it imports comes
    # from the runtime rather than from a module the loader has.
    _, offered_by_all = imports_and_exports(Path(interpreter))
    per_module = {}
    for module in extensions:
        try:
            wanted, offered = imports_and_exports(module)
        except (IndexError, UnicodeDecodeError):
            continue  # not a wasm module we can read; the import test covers it
        per_module[module] = wanted
        offered_by_all |= offered

    missing = {
        module: sorted(wanted - offered_by_all)
        for module, wanted in per_module.items()
        if wanted - offered_by_all
    }
    if missing:
        for module, syms in missing.items():
            print(
                f"{module.name}: nothing exports {len(syms)} symbol(s) it imports",
                file=sys.stderr,
            )
            for sym in syms[:10]:
                print(f"    {sym}", file=sys.stderr)
        print(
            "-> wasm-ld makes an undefined symbol a GOT import instead of a link error, so a "
            "missing library only fails when wasmer loads the module; add the library it needs.",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"OK {len(per_module)} module(s)")


main()
