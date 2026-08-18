# Code style

How code in this repo is expected to read. Packaging mechanics are
`docs/packaging.md`; build and check commands are `docs/building.md`.

## nixpkgs conventions are the default

This flake is a set of nixpkgs overlays, so nixpkgs conventions are the default:
argument style, phases, `meta`, update scripts, and existing language package
sets. Override those mechanisms instead of building parallel machinery. The
[nixpkgs contributing guide](https://github.com/NixOS/nixpkgs/blob/master/CONTRIBUTING.md)
and the manual's
[coding conventions](https://nixos.org/manual/nixpkgs/stable/#chap-conventions)
are the reference.

Deviate where WASIX genuinely forces it, and say why at the point of divergence.
"Upstream nixpkgs does X" is a sufficient reason to do X; "our version is
neater" is not.

## Comments

Write a comment only when it carries a constraint or a reason the code cannot
show. If it restates the line below it, or narrates what changed, delete it:
change narration belongs in the commit message.

Explain the mechanism, not the incident. The error text, the flag, or the
constraint still means something to someone who was not there; a named past
debugging session does not.

Match the comment density of the surrounding file.

`#` comments inside a build-script string (`postPatch`, `buildPhase`, `''...''`)
are part of the derivation, so editing one changes the drv hash and forces a
rebuild. Keep build strings comment-free and put the rationale in a nix-level
comment above the attribute, which the parser strips.

## Naming

Name things after what they concretely do. If a name needs a comment to explain
it, rename it instead.

Package attrs follow nixpkgs naming. For example, override `gnused` and `gawk`,
not parallel `sed` and `awk` attrs. A differently named attr does not replace
nixpkgs' dependency edge, so existing consumers keep the unmodified package.

## Commits

`<scope>: <summary>`, lowercase, as in nixpkgs. The scope is the thing that
changed, not a category of work: either a package attr name or the subsystem
that owns the change.

```text
wasixcc: 0.4.4 -> 0.4.5
tokio: cover 1.35.1, drop the false pre-1.47 stock range
toolchain: preserve relocatable links in wasixcc
docs: explain ci profile selection
```

The examples are illustrative, not an inventory of valid scopes.

One change touching a few related things takes a brace-expansion scope, and one
sweeping the repo takes `treewide:`:

```text
python{,3-pkgs}: drop the setuptools pin
tests/{curl,git}: cover the proxy path
treewide: reformat with prettier
```

Two nixpkgs summary idioms carry real meaning; use them literally:

- `foo: init at <version>` for a new package that pins its own version. Plain
  `foo: init` is right for an overlay entry that takes its version from nixpkgs,
  since there is no version here to name.
- `foo: <old> -> <new>` for a version bump, and nothing else in the summary.

Do not use conventional-commits prefixes. `feat:` and `fix:` name a kind of
change rather than a component, which is the opposite of what the scope is for.

Pin bumps are generated: `wasinix update --all --commit` lands one commit per
target, already in `<name>: <old> -> <new>` form, plus a separate commit for
each repo-wide step a bump implies (history retention, rels pruning, a package's
post-update hook). Let it write those rather than hand-rolling a variant.

A meaningful title is enough when the diff explains the change. Use a short body
for rationale the diff cannot show, not to narrate what changed.

A commit written with AI assistance says so with an `Assisted-by:` trailer
naming the harness and the model:

```text
Assisted-by: <harness>:<model>
```

Do not use `Co-authored-by:`, which credits a person. Add no email or URL. Name
the model the tool reports; if it is hidden, use `<harness>:auto`.

Keep a change's diff to what it needs. Drive-by refactors, silently dropped
code, and unexplained commit splits all cost a reviewer time.

## Fail loud

No guarding, no silent fallbacks, no defaults that paper over a missing input.

- Do not add an existence check before using a path that should exist. Let it
  fail.
- Do not return success for a missing or invalid input.
- Do not drop a check (`outputChecks`, a test, a lint) to make something pass.
  If the check is right and the output is wrong, fix the output.
- Do not silently substitute a reduced variant for the thing asked for. `bash`
  means bash, not `bashNonInteractive`.

If removing a guard makes the code longer, the guard is still there.

## Root cause, not cosmetics

- A failing target gets fixed, not excluded, skipped, or marked broken.
  Shrinking the build set to go green needs the user's explicit agreement, and
  they can only give it once you have said what stops being covered and why the
  fix is untenable rather than merely expensive. Accepting a regression is
  occasionally right. It is never the first move, and never a silent one.
- Fix a bug at the scope it exists at. If it affects every test, fix it for
  every test.
- When you fix one instance, grep for structurally identical ones and fix them
  together.
- "It is not reproducible" is not a finding. If a real program hits the bug,
  start from that program and strip it down until the failure is isolated.
- wasmer and the WASIX toolchains are ours to diagnose, not third-party black
  boxes. Name the root fix, vendor it as a patch when possible, and record any
  shipping workaround in `WASIX-TODO.md`. Upstreaming the fix is welcome but
  does not gate a change here.
- Describe a regression as a regression. An approving adjective ("honest",
  "cleaner", "pragmatic") on a tradeoff hides the decision the reader needs to
  make.

## Import from derivation

IFD is allowed and strongly discouraged. It serialises eval behind a build, so
it slows every consumer of the attribute and turns an eval-time error into a
build-time one.

Reach for it only when the alternative is worse, and say which alternative in a
comment at the site. The rust vendor patching is the standing example: it reads
each vendor's crate set at eval so that editing one crate's patch rebuilds only
the vendors containing it (`docs/rust.md`).

## Single source of truth

- If a comment says two pieces of code must "agree" or "stay in sync", extract
  the shared implementation instead of writing the comment.
- Never hardcode a value already available from a canonical source: the version
  comes from the derivation, toolchain flags from the surrounding profile, the
  owner from the shared default.
- Reference well-known store paths and declared inputs directly. Do not `find`
  or PATH-search for something whose location is known at eval time.
- Never search `/nix/store` itself. A match is usually the wrong answer: the
  store keeps every version ever built, including results from other worktrees
  and older revisions, so a glob happily returns a path the current tree does
  not evaluate to. It is also slow, at a few hundred thousand top-level entries
  whose contents a recursive walk (`find`, `grep -r`, `**`) descends into. Ask
  nix where something is: `nix path-info`, `nix-store -q --references`, or eval
  the attr.
- A feature spanning package types (wheels, CLI packages, libraries) is
  implemented once and driven by data, not copied per type.
- A list in documentation is exhaustive only when that document owns the
  inventory. Otherwise link to the source of truth. Keep a named example only
  when it explains the mechanism, and introduce it as an example; adding another
  consumer does not require updating the example.
- When you replace a pattern, migrate every consumer in the same change.

## Dogfood wasmer

Anything here that needs to run wasm runs it under wasmer: the test harness, a
build step, a throwaway reproduction. We ship a wasm runtime, so reaching for
another one to build our own packages is a smell, and it forfeits the bugs that
using our own is how we find. Use something else only with a stated reason.

## Scope

Build the full package. Do not narrow features, profiles, targets, or
optimisation to match the only consumer that exists today; "nothing else uses it
yet" is not a reason. Narrow against a named technical blocker, and name it in
the commit.

## For agents

Default to a title and the `Assisted-by` trailer, with no body. Add at most a
short paragraph when the rationale is necessary. Do not summarize the diff,
recount the debugging process, or fill a template for its own sake.

Comment volume is the most repeated complaint about AI-authored code here, and
asking for fewer has produced cosmetic trims rather than deletions. Run every
comment in your final diff through these. Failing one check means it goes.

1. Does it restate the line below it? Delete.
2. Does it narrate a change ("bumped because", "no longer needed", "now uses",
   "we used to")? Delete. That belongs in the commit message.
3. Does it name an incident, bug, or session the file never introduces? Rewrite
   as the generic mechanism: the error text, the flag, the constraint.
4. Would a reader who has not seen the change understand every term? If it uses
   a word coined nowhere, delete or define it.
5. Is it longer than three lines inline, or four in a file header? Cut it, or
   move the bulk to the commit message.
6. Does identical code elsewhere in the same change have a different comment?
   Make them identical.
7. Is it true of the code below it, in the right causal direction? A
   technically-true-but-misleading comment is a bug.

Measure density against human-authored neighbours, not code you generated
earlier; matching your own output is circular.

Leave other people's comments alone unless your change falsified them. Rewording
untouched code's comments is diff churn a reviewer has to audit for meaning
drift. A comment you move or rewrite is yours, and gets the checks above.

No metaphors or cryptic abbreviations in names. A name that needs decoding costs
every later reader.

No em dashes in code, comments, commits, PR text, or chat. Fold a necessary
clause into the sentence and delete an aside.
