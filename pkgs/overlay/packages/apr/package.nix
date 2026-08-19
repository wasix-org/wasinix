# wasi has no SIOCATMARK and no fifos, and its sys/socket.h keeps the musl SO_*
# block behind __wasilibc_unmodified_upstream, so SO_DEBUG is absent too; apr
# already reports such gaps as APR_ENOTIMPL. sendfile it implements per OS with
# no wasi branch, so that one stays off rather than reporting a call it cannot make.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/wasi-unsupported-calls.patch];
  # its DSO support needs dlopen, so the PIC sysroots
  passthru.wasix.supportedProfiles = helpers.profiles.pic;
  configureFlags = [
    "ac_cv_func_sendfile=no"
    # a run test, so cross builds take its fallback; wasi's strerror_r is the
    # POSIX one, returning int
    "ac_cv_strerror_r_rc_int=yes"
  ];
}
prev.apr
