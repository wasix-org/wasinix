# Check that built artifacts really target a given profile ABI. Plug in any
# derivations; the check scans them:
#   *.a / *.o           exception-handling target feature (EH profiles only),
#                       PIC-style relocations (R_WASM_*_REL_* / GOT, PIC
#                       profiles only)
#   bin/*.wasm, *.so    dylink.0 section (dynamic modules only), asyncify_*
#                       exports (asyncified binaries only)
# exnref vs legacy EH is not checkable for plain C: without EH instructions the
# flavor leaves no trace in the artifact.
#
# Usage:
#   abiCheck {
#     name = "zlib-off";
#     paths = [ profileSets.off.zlib ];
#     eh = false;          # expect the exception-handling feature?
#     pic = false;         # expect PIC relocations?
#     asyncify = null;     # true/false to check linked wasm, null to skip
#     dylink = null;       # likewise for the dylink.0 section
#   }
{
  lib,
  runCommand,
  wasixLlvm,
  binaryen,
}: {
  name,
  paths,
  eh,
  pic,
  asyncify ? null,
  dylink ? null,
}:
runCommand "abi-check-${name}" {
  nativeBuildInputs = [wasixLlvm binaryen];
} ''
  fail=0
  err() {
    echo "ABI CHECK FAIL($1): $2" >&2
    fail=1
  }

  # ASCII of the target_features custom section (empty if absent). `|| true`
  # everywhere: pipefail + set -e otherwise kill the whole check silently on
  # the first file a tool rejects.
  features_of() {
    { llvm-objdump -s -j target_features "$1" 2>/dev/null || true; } \
      | awk '/^ [0-9a-f]/ {print $NF}' | tr -d '\n'
  }

  # Archives can be linker scripts and .o globs can catch non-wasm files;
  # NULs are dropped by command substitution, so a wasm magic reads "asm".
  checkable() {
    magic=$(head -c 7 "$1" 2>/dev/null | tr -d '\0' || true)
    case "$magic" in
    'asm'*) return 0 ;;      # wasm object
    '!<arch>') return 0 ;;   # ar archive
    *) return 1 ;;
    esac
  }

  sawPicReloc=0
  checkedObjects=0
  for p in ${lib.escapeShellArgs (map toString paths)}; do
    while IFS= read -r f; do
      checkable "$f" || continue
      checkedObjects=1
      feats=$(features_of "$f")
      case "$feats" in
      *exception-handling*) hasEh=1 ;;
      *) hasEh=0 ;;
      esac
      ${
    if eh
    then ''[ "$hasEh" = 1 ] || err "$f" "exception-handling feature missing (expected an EH profile object)"''
    else ''[ "$hasEh" = 0 ] || err "$f" "exception-handling feature present (expected an off-profile object)"''
  }

      relocs=$({ llvm-readobj --relocations "$f" 2>/dev/null || true; } | { grep -oE 'R_WASM_[A-Z_0-9]+' || true; } | sort -u)
      picRelocs=$(printf '%s\n' "$relocs" | { grep -cE 'R_WASM_(GOT|[A-Z_]*_REL_)' || true; })
      if [ "$picRelocs" -gt 0 ]; then sawPicReloc=1; fi
      ${lib.optionalString (!pic) ''
    [ "$picRelocs" -eq 0 ] || err "$f" "PIC relocations present (expected a non-PIC profile object)"
  ''}
    done < <(find "$p" -name '*.a' -o -name '*.o')
  done
  ${lib.optionalString pic ''
    # Existence check across the whole set: address-taking code in a PIC profile
    # must produce at least one GOT/relative relocation.
    if [ "$checkedObjects" = 1 ] && [ "$sawPicReloc" = 0 ]; then
      err "(all objects)" "no PIC relocations found (expected a PIC profile)"
    fi
  ''}

  for p in ${lib.escapeShellArgs (map toString paths)}; do
    while IFS= read -r f; do
      checkable "$f" || continue
      hasDylink=0
      n=$({ llvm-objdump -h "$f" 2>/dev/null || true; } | { grep -c 'dylink' || true; })
      if [ "$n" -gt 0 ]; then hasDylink=1; fi
      ${
    if dylink == null
    then ""
    else if dylink
    then ''[ "$hasDylink" = 1 ] || err "$f" "dylink.0 section missing (expected a dynamic module)"''
    else ''[ "$hasDylink" = 0 ] || err "$f" "dylink.0 section present (expected a static module)"''
  }
      ${lib.optionalString (asyncify != null) ''
    # grep -c, not -q: -q closes the pipe at the first match, wasm-dis dies of
    # SIGPIPE, and pipefail turns that into a failure exactly on success.
    hasAsyncify=0
    n=$(wasm-dis "$f" 2>/dev/null | grep -c '(export "asyncify_get_state"' || true)
    if [ "$n" -gt 0 ]; then hasAsyncify=1; fi
    ${
      if asyncify == true
      then ''[ "$hasAsyncify" = 1 ] || err "$f" "asyncify exports missing (fork/setjmp would trap)"''
      else ''[ "$hasAsyncify" = 0 ] || err "$f" "asyncify exports present (unexpected instrumentation)"''
    }
  ''}
    done < <(find "$p" \( -path '*/bin/*.wasm' -o -name '*.so' \) -type f)
  done

  [ "$fail" = 0 ] || exit 1
  echo "abi-check ${name}: ok" | tee "$out"
''
