{lib}: {
  # Add a payload without silently replacing a file newly supplied upstream.
  addFile = source: target: ''
    if [[ -e ${lib.escapeShellArg target} || -L ${lib.escapeShellArg target} ]]; then
      printf '%s\n' ${lib.escapeShellArg "crate-edits: ${target} already exists"} >&2
      exit 1
    fi
    cp ${source} ${lib.escapeShellArg target}
  '';
}
