# util-linux for wasix, built for libuuid only (cpython's _uuid backend;
# nixpkgs sets libuuid = null off Linux). Everything else is disabled: only
# libuuid.a + uuid/uuid.h are needed, and the programs pull in far more
# Linux-only syscalls. gen_uuid.c's MAC-address node-id path uses SIOCGIFCONF
# (no network-interface enumeration on wasix); gating it off leaves the
# random-node-id fallback, which uuid_generate_time already handles.
{
  prev,
  helpers,
  ...
}: let
  lib = prev.lib;
in
  helpers.libTweaks {
    configureFlags = [
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
    # single output: nixpkgs splits bin/lib/dev/man/login and routes libuuid.a
    # to the `lib` placeholder via makeFlags; with programs disabled most of
    # those come out empty. Collapse to `out` and redirect the exec dirs there
    # (last make assignment wins over nixpkgs' placeholder ones).
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
    postPatch = ''
      substituteInPlace libuuid/src/gen_uuid.c \
        --replace-fail '#ifdef HAVE_NET_IF_H' '#if defined(HAVE_NET_IF_H) && !defined(__wasi__)'
    '';
    # libuuid uses poll (present only in the PIC sysroots, cf. mariadb).
    passthru.wasix.supportedProfiles = helpers.profiles.pic;
  }
  prev.util-linux
