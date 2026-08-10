# Write a wasix fork's added crate deps into a Cargo.lock so the vendor resolves
# them normally. The forks declare what they add co-located
# (wasix-crate-patches/<crate>/wasix.nix `adds`); each entry is {crate (the adder), name
# (the added dep), version, checksum, deps}. For each whose adder crate is
# present at one of the versions that pull it, and whose added dep
# isn't already in the lock: add the dep to the
# adder's `dependencies`, and insert the dep's own `[[package]]` block, both in
# cargo's alphabetical order, so the result is what `cargo` itself would have
# written. Applied by the patch machinery, not called per package.
#
#   amend-lock.py <cargo.lock> <adds.json>   (amended lock -> stdout)
import json
import re
import sys

text = open(sys.argv[1]).read()
adds = json.load(open(sys.argv[2]))

# Split into the preamble and one chunk per [[package]] block (each chunk keeps
# its trailing blank line, so re-joining is byte-preserving).
chunks = re.split(r"(?=^\[\[package\]\]$)", text, flags=re.M)
preamble, blocks = chunks[0], chunks[1:]


def name_of(block):
    m = re.search(r'^name = "(.*)"$', block, re.M)
    return m.group(1) if m else ""


def version_of(block):
    m = re.search(r'^version = "(.*)"$', block, re.M)
    return m.group(1) if m else ""


def dep_key(entry):
    m = re.search(r'"(.*)"', entry)
    return m.group(1) if m else ""


def add_dep(block, dep):
    lines = block.split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == "dependencies = [")
    except StopIteration:
        raise SystemExit(
            f"amend-lock: {name_of(block)} has no dependencies array to add {dep} to"
        )
    end = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "]")
    entries = lines[start + 1 : end]
    new = f' "{dep}",'
    if new in entries:
        return block
    entries = sorted(entries + [new], key=dep_key)
    return "\n".join(lines[: start + 1] + entries + lines[end:])


def make_block(inj):
    deps = "".join(f' "{d}",\n' for d in sorted(inj["deps"]))
    deps = f"dependencies = [\n{deps}]\n" if inj["deps"] else ""
    return (
        "[[package]]\n"
        f'name = "{inj["name"]}"\n'
        f'version = "{inj["version"]}"\n'
        'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
        f'checksum = "{inj["checksum"]}"\n'
        f"{deps}"
        "\n"
    )


present = {name_of(b) for b in blocks}
pairs = {(name_of(b), version_of(b)) for b in blocks}
for a in adds:
    if a["name"] in present:
        continue
    if not any((a["crate"], v) in pairs for v in a["versions"]):
        continue
    blocks = [add_dep(b, a["name"]) if name_of(b) == a["crate"] else b for b in blocks]
    pos = next((i for i, b in enumerate(blocks) if name_of(b) > a["name"]), len(blocks))
    blocks.insert(pos, make_block(a))
    present.add(a["name"])

sys.stdout.write(preamble + "".join(blocks))
