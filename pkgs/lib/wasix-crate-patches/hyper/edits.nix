# hyper: the 0.14 line builds its outbound socket from a raw fd behind a `unix`
# gate, which wasi satisfies too. One line, one file, unchanged across the line,
# so it is a substitution rather than eleven near-identical floors. 1.x builds
# stock (verified on 1.6 and 1.9, which this tree builds against).
{...}: {
  edited = [">=0.14.18, <0.15.0"];
  stock = ["<0.14.18" ">=0.15.0"];
  forVersion = {...}: {
    patches = [];
    patchPhase = ''
      substituteInPlace src/client/connect/http.rs \
        --replace-fail '#[cfg(unix)]' '#[cfg(any(unix, target_os = "wasi"))]'
    '';
  };
}
