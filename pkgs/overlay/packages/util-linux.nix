# util-linux for wasix, built for libuuid only (cpython's _uuid backend; nixpkgs
# sets libuuid = null off Linux).
{
  prev,
  helpers,
  ...
}: let
  lib = prev.lib;
in
  helpers.extendPackage prev.util-linux {
    configureFlags = [
      # Every program links libcommon, and libcommon does not compile here:
      # lib/configs.c wants sys/syslog.h, lib/fileutils.c calls fork, and
      # lib/sysfs.c + lib/path.c call major/minor/makedev.
      "--disable-all-programs"
      "--enable-libuuid"
      "--disable-nls"
      "--disable-asciidoc"
      "--without-systemd"
      "--without-python"
      "--without-tinfo"
      "--without-ncurses"
      "--without-ncursesw"
      "--without-cap-ng"
      "--without-selinux"
      "--without-audit"
    ];
    buildInputs = lib.const [];
    nativeBuildInputs = old:
      lib.filter (x: (x.pname or "") != "python3") old;
    # nixpkgs splits bin/lib/dev/man/login and routes libuuid.a to the `lib`
    # placeholder via makeFlags; with programs disabled most come out empty.
    outputs = lib.const ["out"];
    makeFlags = [
      "usrlib_execdir=${placeholder "out"}/lib"
      "usrbin_execdir=${placeholder "out"}/bin"
      "usrsbin_execdir=${placeholder "out"}/sbin"
      "SYSCONFSTATICDIR=${placeholder "out"}/lib"
    ];
    doCheck = false;
    doInstallCheck = false;
    postInstall = lib.const "";
    postFixup = lib.const "";
    # gen_uuid.c's MAC node-id path needs SIOCGIFCONF interface enumeration, which
    # wasix has none of; gating that off leaves the random-node-id fallback.
    postPatch = ''
      substituteInPlace libuuid/src/gen_uuid.c \
        --replace-fail '#ifdef HAVE_NET_IF_H' '#if defined(HAVE_NET_IF_H) && !defined(__wasi__)'
    '';
    # libuuid uses poll (present only in the PIC sysroots, cf. mariadb).
    passthru.wasix.supportedProfiles = helpers.profiles.pic;
  }
