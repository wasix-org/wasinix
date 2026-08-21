# The berkeley-db backend compiles db.h, which spells its types u_int32_t.
# wasi-libc keeps those BSD aliases behind _GNU_SOURCE.
{
  exposeExtendedPackage,
  profileSets,
}:
exposeExtendedPackage {
  env.NIX_CFLAGS_COMPILE = "-D_GNU_SOURCE";
  # apr is PIC-only, and svn links it
  passthru.wasix.supportedProfiles = profileSets.pic;
}
