# wasi has no SIOCATMARK and no fifos, and its sys/socket.h keeps the musl SO_*
# block behind __wasilibc_unmodified_upstream, so SO_DEBUG is absent too; apr
# already reports such gaps as APR_ENOTIMPL. sendfile it implements per OS with
# no wasi branch, so that one stays off rather than reporting a call it cannot make.
{
  exposeWasixExtendedPackage,
  profileSets,
}:
exposeWasixExtendedPackage {
  patches = [./patches/wasi-unsupported-calls.patch];
  # Nixpkgs removes the network tests. Emulated checks run with network access.
  postPatch = _: "";
  # testpoll does not complete after file, locking, subprocess, pipe, and poll failures.
  doCheck = false;
  # check-output has already observed nixpkgs' doCheck, so skip its prebuild too.
  wasixCheckPrebuild = ":";
  # its DSO support needs dlopen, so the PIC sysroots
  passthru.wasix.supportedProfiles = profileSets.pic;
  configureFlags = [
    "ac_cv_func_sendfile=no"
    # a run test, so cross builds take its fallback; wasi's strerror_r is the
    # POSIX one, returning int
    "ac_cv_strerror_r_rc_int=yes"
  ];
}
