{
  testLib,
  wasmerPkgs,
  ...
}: {
  compile-object = testLib.mkWasixRun {
    name = "flang-compile-object";
    wasixPkgs = [wasmerPkgs.flang];
    wasmerArgs = ["--enable-threads"];
    script = ''
      cat > answer.f90 <<'EOF'
      function answer() bind(c)
        use iso_c_binding
        integer(c_int) :: answer
        answer = 42
      end function answer
      EOF
      flang -c answer.f90 -o answer.o
      test -s answer.o
    '';
  };
}
