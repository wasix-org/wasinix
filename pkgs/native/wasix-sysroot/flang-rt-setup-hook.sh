# A Fortran static archive records no link dependency, so a C or C++ consumer
# links one without flang_rt and its _Fortran* symbols go unresolved. Put the
# runtime on the link line of every package this is an input of, the way
# wasixflang appends it to the links it drives itself.
# See pkgs/build-support/setup-hooks/role.bash for the offset.
if [ "${hostOffset:-0}" = 0 ]; then
  export NIX_CFLAGS_LINK+=" -L@libdir@ -lflang_rt.runtime"
fi
