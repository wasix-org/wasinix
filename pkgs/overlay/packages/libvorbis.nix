# lib/Makefile.am's check target directly runs ./test_sharedbook as a rule
# step rather than through automake's TESTS= variable, so the generic
# check-output prebuild's TESTS= override doesn't stop it from being exec'd
# at build time, where no wasmer is present. doCheck=false additionally
# stops a check job from being generated to run it at all (doCheck composes
# after the check-output wrapper reads old.doCheck, so it's invisible to
# the wrapper itself; wasixCheckPrebuild covers that half separately).
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  doCheck = false;
  wasixCheckPrebuild = ":";
}
prev.libvorbis
