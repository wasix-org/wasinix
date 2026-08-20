# GSSAPI means linking krb5, which needs a resolver: res_nsearch, res_ninit,
# dn_expand and the ns_rr parsers, none of which wasi-libc has in any form, and
# krb5 defines its DNS lookup unconditionally. Serf keeps http and https; svn
# over https loses Kerberos and SPNEGO, not basic or digest auth. The stub
# stands in for the argument nixpkgs interpolates before the flag is dropped.
# scons names shared objects .os, which wasixcc does not read as objects
# (WASIX-TODO.md).
{
  prev,
  final,
  helpers,
  ...
}: let
  noKerberos =
    final.runCommand "krb5-unavailable" {outputs = ["out" "dev"];}
    "mkdir -p \"$out\" \"$dev\"";
in
  helpers.extendPackage (prev.serf.override {libkrb5 = noKerberos;}) {
    patches = [./patches/wasi-shared-object-suffix.patch];
    # apr is PIC-only, and serf links it
    passthru.wasix.supportedProfiles = helpers.profiles.pic;
    preConfigure = old:
      final.lib.concatStringsSep "\n"
      (builtins.filter (l: !(final.lib.hasInfix "GSSAPI=" l)) (final.lib.splitString "\n" old));
  }
