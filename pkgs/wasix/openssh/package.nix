# wasi has no resolv.h. openssh includes it unguarded, mostly for the b64_ntop
# and b64_pton declarations BSD keeps there; openbsd-compat carries its own
# copies when the system lacks them. There is no chroot either, so sshd's
# session isolation reports that rather than pretending. ssh forks for
# multiplexing and ProxyCommand, so this builds at the off profile.
{exposeExtendedPackage}:
exposeExtendedPackage {
  patches = [./patches/wasi-unsupported-calls.patch];
  # no SCM_RIGHTS: openssh passes descriptors between its privsep processes and
  # for ControlMaster multiplexing, and already carries a switch for platforms
  # that cannot. wasi's msghdr does carry msg_control, so the probe says yes
  # while struct cmsghdr stays undefined.
  # wasi keeps no login records and has no chroot, so the accounting openssh
  # writes on a session has nothing behind it; it carries switches for each.
  env.NIX_CFLAGS_COMPILE = "-DDISABLE_FD_PASSING -DDISABLE_UTMP -DDISABLE_UTMPX -DDISABLE_WTMP -DDISABLE_WTMPX -DDISABLE_LASTLOG -DDISABLE_LOGIN";
  configureFlags = [
    "ac_cv_have_control_in_msghdr=no"
    "ac_cv_have_accrights_in_msghdr=no"
    # ifaddrs.h exists and getifaddrs does not, and openssh keys BindInterface
    # off the header
    "ac_cv_header_ifaddrs_h=no"
  ];
  passthru.wasix.supportedProfiles = ["off"];
}
